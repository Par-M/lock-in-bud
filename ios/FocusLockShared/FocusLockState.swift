import Foundation
import FamilyControls
import ManagedSettings
import Darwin

struct FocusLockSession: Codable {
    var id: String
    var profile: String
    var strict: Bool
    var selection: FamilyActivitySelection
    var expiresAt: Date
    var exceptionToken: ApplicationToken?
    var exceptionUntil: Date?
    var exceptionID: String?
    var exceptionCount = 0

    func blockedApplications(at now: Date) -> Set<ApplicationToken> {
        guard expiresAt > now else { return [] }
        var tokens = selection.applicationTokens
        if let token = exceptionToken, let until = exceptionUntil, until > now { tokens.remove(token) }
        return tokens
    }
    func endingActivity(_ activity: String) -> FocusLockSession? {
        if activity == "lock.session.\(id)" { return nil }
        var result = self
        if let exceptionID, activity == "lock.exception.\(exceptionID)" {
            result.exceptionToken = nil; result.exceptionUntil = nil; result.exceptionID = nil
        }
        return result
    }
    var canRequestException: Bool { !strict || exceptionCount < 2 }
}

enum FocusLockState {
    static let store = ManagedSettingsStore(named: .init("focusLock"))
    private static var stateURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.AM29.MyApp")?.appendingPathComponent("focus-lock-session.json")
    }
    static var session: FocusLockSession? {
        guard let url = stateURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FocusLockSession.self, from: data)
    }
    /// Serialize app/extension read-modify-write operations and shield changes.
    static func update(_ transform: (inout FocusLockSession?) -> Void, at now: Date = .now) {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.AM29.MyApp") else { return }
        let descriptor = open(directory.appendingPathComponent("focus-lock.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        var current = session
        transform(&current)
        if (current?.expiresAt ?? .distantPast) <= now { current = nil }
        if var active = current, let until = active.exceptionUntil, until <= now {
            active.exceptionUntil = nil; active.exceptionToken = nil; active.exceptionID = nil; current = active
        }
        guard let url = stateURL else { store.clearAllSettings(); return }
        do {
            if let current { try JSONEncoder().encode(current).write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { store.clearAllSettings(); return }
        guard let current else { store.clearAllSettings(); return }
        let tokens = current.blockedApplications(at: now)
        store.shield.applications = tokens.isEmpty ? nil : tokens
    }
    static func reconcile(at now: Date = .now) { update({ _ in }, at: now) }
    static func end() { update { $0 = nil } }
}
