import Foundation

final class APIClient {
    var userID: UUID? { keychain.loadSession()?.user.id }
    private let baseURL: URL
    private let keychain: KeychainManaging

    init(baseURL: URL = APIConfiguration.baseURL, keychain: KeychainManaging = KeychainManager()) {
        self.baseURL = baseURL
        self.keychain = keychain
    }

    func loginWithGoogle(idToken: String) async throws -> AuthSession {
        try await send(AuthEndpoint.google(idToken: idToken))
    }

    func loginDev() async throws -> AuthSession {
        try await send(AuthEndpoint.dev(name: "Dev User", email: "dev@example.com"))
    }

    func me() async throws -> User {
        try await send(AuthEndpoint.me)
    }

    func logout() async throws {
        guard let refreshToken = keychain.refreshToken else { return }
        _ = try await send(AuthEndpoint.logout(refreshToken: refreshToken)) as MessageResponse
    }

    func refreshSession() async throws -> AuthSession {
        try await TokenRefresher.shared.refresh(baseURL: baseURL, keychain: keychain)
    }

    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        try await send(endpoint)
    }

    @MainActor
    func streamChat(_ endpoint: Endpoint, onText: @escaping @MainActor (String) -> Void) async throws -> ChatSendResponse {
        try await streamChatAttempt(endpoint, onText: onText, didRetry: false)
    }

    @MainActor
    private func streamChatAttempt(_ endpoint: Endpoint, onText: @escaping @MainActor (String) -> Void, didRetry: Bool) async throws -> ChatSendResponse {
        let owner = userID
        var request = try makeRequest(endpoint)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        if http.statusCode == 401, !didRetry, owner == userID {
            _ = try await refreshSession()
            guard owner == userID else { throw NetworkError.unauthorized }
            return try await streamChatAttempt(endpoint, onText: onText, didRetry: true)
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 16000 { break } }
            throw NetworkError.response(status: http.statusCode, data: data)
        }
        if !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return try JSONCoding.decoder.decode(ChatSendResponse.self, from: data)
        }
        var partial = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard userID == owner else { throw NetworkError.unauthorized }
            guard line.hasPrefix("data:") else { continue }
            let data = Data(line.dropFirst(5).utf8)
            let event = try JSONCoding.decoder.decode(ChatStreamEvent.self, from: data)
            switch event.type {
            case "delta": partial += event.text ?? ""; onText(partial)
            case "tool_status": partial = ""; onText("")
            case "complete": if let result = event.result { return result }
            case "error": throw NetworkError.serverError(status: 502, detail: event.detail ?? "The assistant is unavailable.")
            default: break
            }
        }
        throw NetworkError.serverError(status: 502, detail: "The connection ended before the reply was saved. Your draft was kept.")
    }

    private func send<T: Decodable>(_ endpoint: Endpoint, didRetry: Bool = false) async throws -> T {
        let requestUserID = userID
        let urlRequest = try makeRequest(endpoint)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        if http.statusCode == 401, !didRetry, endpoint.requiresAuthentication, keychain.refreshToken != nil {
            guard userID == requestUserID else { throw NetworkError.unauthorized }
            _ = try await refreshSession()
            guard userID == requestUserID else { throw NetworkError.unauthorized }
            if let auth = endpoint as? AuthEndpoint, case .logout = auth, let token = keychain.refreshToken {
                return try await send(AuthEndpoint.logout(refreshToken: token), didRetry: true)
            }
            return try await send(endpoint, didRetry: true)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.response(status: http.statusCode, data: data)
        }

        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(error)
        }
    }

    private func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = endpoint.queryItems
        guard let url = components?.url else {
            throw NetworkError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if endpoint.requiresAuthentication, let accessToken = keychain.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body = endpoint.body {
            request.httpBody = try JSONCoding.encoder.encode(body)
        }

        return request
    }
}

struct MessageResponse: Decodable {
    let message: String
}

/// Serializes token refreshes across every ``APIClient`` instance.
///
/// Each service builds its own ``APIClient``, but they all share the same
/// keychain and base URL. When several requests hit a 401 at once (for example
/// the focus dashboard's parallel loads), a naive per-client refresh issues
/// multiple `POST /auth/refresh` calls carrying the *same* token, which the
/// server used to treat as theft and revoke the user's entire session.
///
/// Routing every refresh through this single-flight coordinator guarantees at
/// most one in-flight refresh per server/token pair; concurrent callers await
/// the same result without sharing refreshes across accounts.
@MainActor
private final class TokenRefresher {
    static let shared = TokenRefresher()

    private var inFlight: [String: Task<AuthSession, Error>] = [:]

    func refresh(baseURL: URL, keychain: KeychainManaging) async throws -> AuthSession {
        guard let refreshToken = keychain.refreshToken else { throw NetworkError.unauthorized }
        let flightKey = baseURL.absoluteString + "|" + refreshToken
        if let ongoing = inFlight[flightKey] {
            return try await ongoing.value
        }

        let task = Task<AuthSession, Error> {
            let url = baseURL.appending(path: AuthEndpoint.refresh(refreshToken: refreshToken).path)
            var request = URLRequest(url: url)
            request.httpMethod = HTTPMethod.post.rawValue
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCoding.encoder.encode(RefreshRequest(refreshToken: refreshToken))

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NetworkError.response(status: http.statusCode, data: data)
            }

            let session = try JSONCoding.decoder.decode(AuthSession.self, from: data)
            guard keychain.refreshToken == refreshToken else { throw NetworkError.unauthorized }
            keychain.save(session)
            return session
        }

        inFlight[flightKey] = task
        defer { inFlight[flightKey] = nil }
        return try await task.value
    }
}
