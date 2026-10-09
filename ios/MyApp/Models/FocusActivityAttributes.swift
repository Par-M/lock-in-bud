import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@available(iOS 16.1, *)
nonisolated public struct FocusActivityAttributes: ActivityAttributes, Sendable {
    nonisolated public struct ContentState: Codable, Hashable, Sendable {
        public var elapsedSeconds: Int
        public var isPaused: Bool

        public init(elapsedSeconds: Int, isPaused: Bool = false) {
            self.elapsedSeconds = elapsedSeconds
            self.isPaused = isPaused
        }
    }

    public var taskTitle: String
    public var startedAt: Date

    public init(taskTitle: String, startedAt: Date) {
        self.taskTitle = taskTitle
        self.startedAt = startedAt
    }
}

@available(iOS 16.1, *)
@MainActor
public enum FocusLiveActivityManager {
    public static func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = FocusActivityAttributes(taskTitle: FocusTimerStarter.activeTaskTitle ?? "Focus session", startedAt: Date().addingTimeInterval(-Double(FocusTimerStarter.elapsedSeconds())))
        let state = FocusActivityAttributes.ContentState(elapsedSeconds: 0, isPaused: false)
        do {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } else {
                _ = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
            }
        } catch {
            print("Live Activity request failed: \(error)")
        }
    }

    public static func endLiveActivity(elapsedSeconds: Int) async {
        let state = FocusActivityAttributes.ContentState(elapsedSeconds: elapsedSeconds, isPaused: false)
        for activity in Activity<FocusActivityAttributes>.activities {
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                await activity.end(content, dismissalPolicy: .immediate)
            } else {
                await activity.end(using: state, dismissalPolicy: .immediate)
            }
        }
    }
}
#else
@MainActor
public enum FocusLiveActivityManager {
    public static func startLiveActivity() {}

    public static func endLiveActivity(elapsedSeconds: Int) async {}
}
#endif