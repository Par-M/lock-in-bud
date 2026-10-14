import Foundation
import Observation
import FamilyControls
import ManagedSettings
import DeviceActivity

@MainActor @Observable
final class FocusLockService {
    static let shared = FocusLockService()
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "focusLock.enabled") } }
    var profile: String { didSet { UserDefaults.standard.set(profile, forKey: "focusLock.profile") } }
    var strict: Bool { didSet { UserDefaults.standard.set(strict, forKey: "focusLock.strict") } }
    var selection = FamilyActivitySelection()
    var issue: String?
    var session: FocusLockSession?
    var authorized: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }
    private let center = DeviceActivityCenter()
    private init() {
        enabled = UserDefaults.standard.bool(forKey: "focusLock.enabled")
        profile = UserDefaults.standard.string(forKey: "focusLock.profile") ?? "Study"
        strict = UserDefaults.standard.bool(forKey: "focusLock.strict")
        loadProfile()
        session = FocusLockState.session
    }
    func loadProfile() {
        selection = UserDefaults.standard.data(forKey: "focusLock.profile.\(profile)").flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) } ?? FamilyActivitySelection()
    }
    func saveProfile() {
        // Individual apps only: category shields would also block a temporarily allowed app.
        selection.categoryTokens = []; selection.webDomainTokens = []
        if let data = try? JSONEncoder().encode(selection) { UserDefaults.standard.set(data, forKey: "focusLock.profile.\(profile)") }
    }
    func authorize() async {
        do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual); issue = nil }
        catch { issue = "Screen Time access was not granted. Your focus timer still works." }
    }
    func refresh() {
        if !authorized { end(); return }
        FocusLockState.reconcile(); session = FocusLockState.session
    }
    func start() {
        guard enabled else { return }
        guard authorized else { issue = "Focus Lock is off: enable Screen Time access in Focus Lock settings."; return }
        guard !selection.applicationTokens.isEmpty else { issue = "Focus Lock is off: choose individual apps to block."; return }
        end()
        let current = FocusLockSession(id: UUID().uuidString, profile: profile, strict: strict, selection: selection, expiresAt: Date().addingTimeInterval(7200))
        do {
            try monitor(name: "lock.session.\(current.id)", seconds: 7200)
            FocusLockState.update { $0 = current }; session = FocusLockState.session; issue = session == nil ? "Focus Lock could not save its session. Apps remain available." : nil
        } catch { issue = "Couldn’t schedule Focus Lock. Apps remain available; try enabling it again." }
    }
    private func monitor(name: String, seconds: Int) throws {
        let now = Date()
        // A 15-minute interval with an end warning supports short exception windows.
        let interval = max(900, seconds)
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let schedule = DeviceActivitySchedule(intervalStart: Calendar.current.dateComponents(components, from: now), intervalEnd: Calendar.current.dateComponents(components, from: now.addingTimeInterval(Double(interval))), repeats: false, warningTime: seconds < interval ? DateComponents(second: interval - seconds) : nil)
        try center.startMonitoring(DeviceActivityName(name), during: schedule)
    }
    func allow(_ token: ApplicationToken, minutes: Int, reason: String) {
        refresh()
        guard var current = FocusLockState.session, current.canRequestException, current.exceptionUntil.map({ $0 <= .now }) ?? true, current.selection.applicationTokens.contains(token), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, [2, 5].contains(minutes) else { issue = "Choose a blocked app and a reason. Only one exception can be active."; return }
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix("lock.exception.") })
        let id = UUID().uuidString
        do {
            try monitor(name: "lock.exception.\(id)", seconds: minutes * 60)
            current.exceptionToken = token; current.exceptionUntil = min(.now.addingTimeInterval(Double(minutes * 60)), current.expiresAt); current.exceptionID = id; current.exceptionCount += 1
            FocusLockState.update { stored in if stored?.id == current.id { stored = current } }; session = FocusLockState.session; issue = session?.exceptionID == id ? nil : "Couldn’t save the exception. Return to focus and try again."
        } catch { issue = "Couldn’t schedule automatic reblocking. The app remains blocked." }
        // Reasons stay on screen only; no message contents or reasons are uploaded.
    }
    func returnToFocus() {
        guard var current = FocusLockState.session else { return }
        if let id = current.exceptionID { center.stopMonitoring([DeviceActivityName("lock.exception.\(id)")]) }
        current.exceptionToken = nil; current.exceptionUntil = nil; current.exceptionID = nil
        FocusLockState.update { stored in if stored?.id == current.id { stored = current } }; session = FocusLockState.session
    }
    func end() {
        // Remove the durable state first so queued extension callbacks cannot restore shields.
        FocusLockState.end()
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix("lock.") })
        session = nil
    }
    func resetAccount() {
        end(); enabled = false
        for name in ["Study", "Work", "Workout"] { UserDefaults.standard.removeObject(forKey: "focusLock.profile.\(name)") }
        profile = "Study"; strict = false; selection = FamilyActivitySelection(); issue = nil
    }
}
