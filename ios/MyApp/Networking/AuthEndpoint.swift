import Foundation

struct GoogleLoginRequest: Encodable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

struct DevLoginRequest: Encodable {
    let name: String
    let email: String
}

struct RefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

enum AuthEndpoint: Endpoint {
    case google(idToken: String)
    case dev(name: String, email: String)
    case refresh(refreshToken: String)
    case me
    case logout(refreshToken: String)

    var path: String {
        switch self {
        case .google:
            return "/api/v1/auth/google"
        case .dev:
            return "/api/v1/auth/dev"
        case .refresh:
            return "/api/v1/auth/refresh"
        case .me:
            return "/api/v1/auth/me"
        case .logout:
            return "/api/v1/auth/logout"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .google, .dev, .refresh, .logout:
            return .post
        case .me:
            return .get
        }
    }

    var body: (any Encodable)? {
        switch self {
        case .google(let idToken):
            return GoogleLoginRequest(idToken: idToken)
        case .dev(let name, let email):
            return DevLoginRequest(name: name, email: email)
        case .refresh(let refreshToken):
            return RefreshRequest(refreshToken: refreshToken)
        case .logout(let refreshToken):
            return RefreshRequest(refreshToken: refreshToken)
        case .me:
            return nil
        }
    }

    var requiresAuthentication: Bool {
        switch self {
        case .google, .dev, .refresh:
            return false
        case .me, .logout:
            return true
        }
    }
}
