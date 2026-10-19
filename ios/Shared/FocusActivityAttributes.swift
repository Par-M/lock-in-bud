import Foundation

/// The saved timer projected at a particular instant, shared with the widget.
nonisolated struct FocusLockScreenSnapshot: Equatable, Sendable {
    let sessionID: String
    let taskTitle: String
    let elapsedSeconds: Int
    let isPaused: Bool
    let timerStartedAt: Date
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@available(iOS 16.1, *)
nonisolated public struct FocusActivityAttributes: ActivityAttributes, Sendable {
    nonisolated public struct ContentState: Codable, Hashable, Sendable {
        public var elapsedSeconds: Int
        public var isPaused: Bool
        /// Effective origin excludes breaks, so the system can animate the timer without app updates.
        public var timerStartedAt: Date

        public init(elapsedSeconds: Int, isPaused: Bool, timerStartedAt: Date) {
            self.elapsedSeconds = max(0, elapsedSeconds)
            self.isPaused = isPaused
            self.timerStartedAt = timerStartedAt
        }
    }

    public var sessionID: String
    public var taskTitle: String
}

@available(iOS 16.1, *)
extension FocusLockScreenSnapshot {
    var contentState: FocusActivityAttributes.ContentState {
        .init(elapsedSeconds: elapsedSeconds, isPaused: isPaused, timerStartedAt: timerStartedAt)
    }
}
#endif
