import Foundation
import Observation
import UIKit

struct FocusActivityReference: Equatable {
    let id: String
    let sessionID: String
}

@MainActor
protocol FocusActivityClient {
    var isEnabled: Bool { get }
    var activities: [FocusActivityReference] { get }
    func request(_ snapshot: FocusLockScreenSnapshot) throws
    func update(_ activity: FocusActivityReference, snapshot: FocusLockScreenSnapshot) async
    func end(_ activity: FocusActivityReference) async
}

/// Operations run in order: a delayed pause/stop cannot overwrite a newer session.
@MainActor @Observable
final class FocusLiveActivityManager {
    static let shared = FocusLiveActivityManager()
    private(set) var message: String?
    private let client: any FocusActivityClient
    private let canStart: @MainActor () -> Bool
    private var pending: Task<Void, Never>?

    init(client: (any FocusActivityClient)? = nil, canStart: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.client = client ?? SystemFocusActivityClient()
        self.canStart = canStart
    }

    static func synchronize() {
        shared.enqueue(FocusTimerStarter.lockScreenSnapshot())
    }

    @discardableResult
    func enqueue(_ snapshot: FocusLockScreenSnapshot?) -> Task<Void, Never> {
        let previous = pending
        let operation = Task { @MainActor in
            await previous?.value
            await reconcile(snapshot)
        }
        pending = operation
        return operation
    }

    private func reconcile(_ snapshot: FocusLockScreenSnapshot?) async {
        let activities = client.activities
        guard let snapshot else {
            for activity in activities { await client.end(activity) }
            message = nil
            return
        }
        var matching: FocusActivityReference?
        for activity in activities {
            if activity.sessionID == snapshot.sessionID && matching == nil { matching = activity }
            else { await client.end(activity) }
        }
        guard client.isEnabled else {
            message = "Lock-screen timer unavailable. Allow Live Activities for Lock In Bud in Settings. Your focus timer keeps running."
            return
        }
        if let matching {
            await client.update(matching, snapshot: snapshot)
            message = nil
        } else if canStart() {
            do {
                try client.request(snapshot)
                message = nil
            } catch {
                message = "Couldn’t show the lock-screen timer. Try again while Lock In Bud is open. Your focus timer keeps running."
            }
        }
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@MainActor
private final class SystemFocusActivityClient: FocusActivityClient {
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var activities: [FocusActivityReference] {
        Activity<FocusActivityAttributes>.activities.map { .init(id: $0.id, sessionID: $0.attributes.sessionID) }
    }
    func request(_ snapshot: FocusLockScreenSnapshot) throws {
        let attributes = FocusActivityAttributes(sessionID: snapshot.sessionID, taskTitle: snapshot.taskTitle)
        _ = try Activity.request(attributes: attributes, content: ActivityContent(state: snapshot.contentState, staleDate: nil), pushType: nil)
    }
    func update(_ activity: FocusActivityReference, snapshot: FocusLockScreenSnapshot) async {
        guard let current = Activity<FocusActivityAttributes>.activities.first(where: { $0.id == activity.id }) else { return }
        await current.update(ActivityContent(state: snapshot.contentState, staleDate: nil))
    }
    func end(_ activity: FocusActivityReference) async {
        guard let current = Activity<FocusActivityAttributes>.activities.first(where: { $0.id == activity.id }) else { return }
        await current.end(nil, dismissalPolicy: .immediate)
    }
}
#else
@MainActor
private final class SystemFocusActivityClient: FocusActivityClient {
    var isEnabled: Bool { false }
    var activities: [FocusActivityReference] { [] }
    func request(_ snapshot: FocusLockScreenSnapshot) throws {}
    func update(_ activity: FocusActivityReference, snapshot: FocusLockScreenSnapshot) async {}
    func end(_ activity: FocusActivityReference) async {}
}
#endif
