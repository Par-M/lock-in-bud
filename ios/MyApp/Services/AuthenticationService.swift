import Foundation
import Observation

@MainActor
@Observable
final class AuthenticationService {
    enum State {
        case unknown
        case signedOut
        case signedIn
    }

    private(set) var state: State = .unknown
    private(set) var user: User?

    private let apiClient: APIClient
    private let keychain: KeychainManaging
    private let googleProvider: GoogleAuthProvider
    private let localStore: LocalStore?

    init(
        apiClient: APIClient? = nil,
        keychain: KeychainManaging? = nil,
        googleProvider: GoogleAuthProvider? = nil,
        localStore: LocalStore? = nil
    ) {
        self.apiClient = apiClient ?? APIClient()
        self.keychain = keychain ?? KeychainManager()
        self.googleProvider = googleProvider ?? GoogleAuthProvider()
        self.localStore = localStore
    }

    func restoreSession() async {
        guard let stored = keychain.loadSession() else {
            FocusTimerStarter.synchronizeAccount(nil)
            state = .signedOut
            return
        }
        FocusTimerStarter.synchronizeAccount(stored.user.id)

        do {
            user = try await apiClient.me()
            state = .signedIn
        } catch {
            if isDefinitiveSignOut(error) {
                keychain.clear()
                FocusTimerStarter.synchronizeAccount(nil)
                user = nil
                state = .signedOut
            } else {
                // Transient failure (offline, server hiccup). Keep the cached
                // session so the next opportunity can refresh instead of
                // forcing an unnecessary sign-in. `me()` already refreshed
                // through the client's 401 path, so a definitive 401 here
                // really does mean the refresh token was rejected.
                user = stored.user
                state = .signedIn
            }
        }
    }

    /// Revalidate the session when the app returns to the foreground.
    ///
    /// The access token expires after a short window, so without this a user
    /// who backgrounds the app for a while would hit a wall of 401s (and the
    /// scary "sign in again" banner) on their next interaction. `me()` goes
    /// through the client's 401 path, which transparently refreshes the tokens
    /// before retrying, so revalidation is invisible to the user.
    func revalidateSession() async {
        guard keychain.loadSession() != nil else {
            FocusTimerStarter.synchronizeAccount(nil)
            if state != .signedOut {
                user = nil
                state = .signedOut
            }
            return
        }

        do {
            user = try await apiClient.me()
            state = .signedIn
        } catch {
            if isDefinitiveSignOut(error) {
                keychain.clear()
                FocusTimerStarter.synchronizeAccount(nil)
                user = nil
                state = .signedOut
            }
            // Transient failures are swallowed here on purpose: a backgrounded
            // app that reconnects later must not be logged out.
        }
    }

    func signInWithGoogle() async throws {
        let idToken = try await googleProvider.idToken()
        let session = try await apiClient.loginWithGoogle(idToken: idToken)
        apply(session)
    }

    func signInDev() async throws {
        let session = try await apiClient.loginDev()
        apply(session)
    }

    func signOut() {
        FocusTimerStarter.synchronizeAccount(nil)
        user = nil
        state = .signedOut
        localStore?.clearAll()

        let signingOutUserID = keychain.loadSession()?.user.id
        Task {
            if signingOutUserID != nil {
                try? await apiClient.logout()
            }
            await NotificationService.shared.unregisterDevice()
            NotificationService.shared.clearLocalState()
            if keychain.loadSession()?.user.id == signingOutUserID { keychain.clear() }
        }
    }

    private func isDefinitiveSignOut(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkError else { return false }
        if case .unauthorized = networkError { return true }
        return false
    }

    private func apply(_ session: AuthSession) {
        if let previous = keychain.loadSession(), previous.user.id != session.user.id {
            localStore?.clearAll()
        }
        FocusTimerStarter.synchronizeAccount(session.user.id)
        keychain.save(session)
        user = session.user
        state = .signedIn
    }
}
