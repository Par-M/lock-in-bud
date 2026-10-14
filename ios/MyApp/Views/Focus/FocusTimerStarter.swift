import Foundation
import WidgetKit

@MainActor
enum FocusTimerStarter {
    static let pausedAtKey = "focusTimerPausedAt"
    static let pausedSecondsKey = "focusTimerPausedSeconds"
    static let startedAtKey = "focusTimerStartedAt"
    static let activeTaskIDKey = "focusActiveTaskID"
    static let activeTaskTitleKey = "focusActiveTaskTitle"
    static let activeCategoryKey = "focusActiveCategory"
    static let ownerKey = "focusTimerUserID"

    static func synchronizeAccount(_ userID: UUID?) {
        let owner = userID?.uuidString
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: ownerKey) != owner || (userID == nil && startedAt > 0) else { return }
        defaults.removeObject(forKey: pausedAtKey)
        defaults.removeObject(forKey: pausedSecondsKey)
        defaults.removeObject(forKey: startedAtKey)
        clearActiveTask()
        defaults.set(owner, forKey: ownerKey)
        WidgetDataStore.writeFocus(startedAt: 0)
        WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
        if #available(iOS 16.1, *) {
            Task { await FocusLiveActivityManager.endLiveActivity(elapsedSeconds: 0) }
        }
    }

    static var activeTaskID: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: activeTaskIDKey),
              let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    static var activeTaskTitle: String? {
        let value = UserDefaults.standard.string(forKey: activeTaskTitleKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static var activeCategory: String? {
        let value = UserDefaults.standard.string(forKey: activeCategoryKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static var startedAt: TimeInterval {
        UserDefaults.standard.double(forKey: startedAtKey)
    }

    /// Starts the app-wide focus timer, optionally tied to a task so the logged
    /// session can be attributed to that task's category and remaining time.
    static func startFocus(
        taskID: UUID? = nil,
        title: String? = nil,
        category: String? = nil,
        keychain: KeychainManaging? = nil
    ) {
        guard let userID = (keychain ?? KeychainManager()).loadSession()?.user.id else { return }
        synchronizeAccount(userID)
        guard self.startedAt <= 0 else { return }
        let defaults = UserDefaults.standard
        let startedAt = Date().timeIntervalSince1970

        defaults.removeObject(forKey: pausedAtKey)
        defaults.removeObject(forKey: pausedSecondsKey)
        defaults.set(startedAt, forKey: startedAtKey)

        if let taskID {
            defaults.set(taskID.uuidString, forKey: activeTaskIDKey)
        } else {
            defaults.removeObject(forKey: activeTaskIDKey)
        }

        if let title, !title.isEmpty {
            defaults.set(title, forKey: activeTaskTitleKey)
        } else {
            defaults.removeObject(forKey: activeTaskTitleKey)
        }

        if let category, !category.isEmpty {
            defaults.set(category, forKey: activeCategoryKey)
        } else {
            defaults.removeObject(forKey: activeCategoryKey)
        }

        WidgetDataStore.writeFocus(startedAt: startedAt, title: title ?? "Deep Work Session")
        WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")

        if #available(iOS 16.1, *) {
            FocusLiveActivityManager.startLiveActivity()
        }
    }

    static var isPaused: Bool { UserDefaults.standard.double(forKey: pausedAtKey) > 0 }
    static func elapsedSeconds(at now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        guard startedAt > 0 else { return 0 }
        let paused = UserDefaults.standard.double(forKey: pausedAtKey)
        let total = UserDefaults.standard.double(forKey: pausedSecondsKey)
        return max(0, Int((paused > 0 ? paused : now) - startedAt - total))
    }
    static func togglePause() {
        guard startedAt > 0 else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let paused = defaults.double(forKey: pausedAtKey)
        if paused > 0 {
            defaults.set(defaults.double(forKey: pausedSecondsKey) + now - paused, forKey: pausedSecondsKey)
            defaults.removeObject(forKey: pausedAtKey)
        } else { defaults.set(now, forKey: pausedAtKey) }
        WidgetDataStore.writeFocus(startedAt: isPaused ? 0 : now - Double(elapsedSeconds()), title: isPaused ? "Paused · " + (activeTaskTitle ?? "Focus session") : activeTaskTitle ?? "Focus session")
        WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
        if #available(iOS 16.1, *) {
            let elapsed = elapsedSeconds()
            let pausedNow = isPaused
            Task {
                await FocusLiveActivityManager.endLiveActivity(elapsedSeconds: elapsed)
                if !pausedNow { FocusLiveActivityManager.startLiveActivity() }
            }
        }
    }

    static func clearActiveTask() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: activeTaskIDKey)
        defaults.removeObject(forKey: activeTaskTitleKey)
        defaults.removeObject(forKey: activeCategoryKey)
    }
}
