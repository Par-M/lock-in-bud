import XCTest
@testable import MyApp

@MainActor
final class FocusLiveActivityTests: XCTestCase {
    private func snapshot(_ id: String = "session", seconds: Int = 120, paused: Bool = false) -> FocusLockScreenSnapshot {
        .init(sessionID: id, taskTitle: "Study", elapsedSeconds: seconds, isPaused: paused, timerStartedAt: Date(timeIntervalSince1970: 1000 - Double(seconds)))
    }

    func testStartingAndReconcilingSessionDoesNotDuplicateActivity() async {
        let client = RecordingFocusActivityClient()
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        await manager.enqueue(snapshot()).value
        await manager.enqueue(snapshot(seconds: 130)).value
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.activities.count, 1)
        XCTAssertEqual(client.updates.last?.elapsedSeconds, 130)
    }

    func testPauseAndResumeUpdateTheExistingCard() async {
        let client = RecordingFocusActivityClient()
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        await manager.enqueue(snapshot()).value
        await manager.enqueue(snapshot(paused: true)).value
        XCTAssertTrue(client.updates.last?.isPaused == true)
        await manager.enqueue(snapshot(seconds: 130)).value
        XCTAssertFalse(client.updates.last?.isPaused ?? true)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.ended.isEmpty)
    }

    func testQueuedStopCannotRemoveANewerSession() async {
        let client = RecordingFocusActivityClient()
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        manager.enqueue(snapshot("old"))
        manager.enqueue(snapshot("old", paused: true))
        manager.enqueue(nil)
        await manager.enqueue(snapshot("new")).value
        XCTAssertEqual(client.activities.map(\.sessionID), ["new"])
        XCTAssertEqual(client.requests.map(\.sessionID), ["old", "new"])
        XCTAssertEqual(client.ended.count, 1)
    }

    func testForegroundRestoreUpdatesMatchingActivityAndRemovesOrphans() async {
        let client = RecordingFocusActivityClient()
        client.activities = [.init(id: "old", sessionID: "other"), .init(id: "current", sessionID: "session"), .init(id: "duplicate", sessionID: "session")]
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        await manager.enqueue(snapshot()).value
        XCTAssertEqual(client.activities.map(\.id), ["current"])
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(client.updates.count, 1)
    }

    func testSignOutCleansUpEvenWhenActivitiesAreDisabled() async {
        let client = RecordingFocusActivityClient()
        client.activities = [.init(id: "one", sessionID: "session")]
        client.isEnabled = false
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        await manager.enqueue(nil).value
        XCTAssertTrue(client.activities.isEmpty)
        XCTAssertNil(manager.message)
    }

    func testPermissionAndRequestFailureKeepTheTimerAvailableAndCanRetry() async {
        let client = RecordingFocusActivityClient()
        let manager = FocusLiveActivityManager(client: client, canStart: { true })
        client.isEnabled = false
        await manager.enqueue(snapshot()).value
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(manager.message?.contains("Settings") == true)
        client.isEnabled = true
        client.shouldFail = true
        await manager.enqueue(snapshot()).value
        XCTAssertTrue(client.activities.isEmpty)
        XCTAssertTrue(manager.message?.contains("keeps running") == true)
        client.shouldFail = false
        await manager.enqueue(snapshot()).value
        XCTAssertEqual(client.activities.count, 1)
        XCTAssertNil(manager.message)
    }

    func testMissingActivityIsNotRequestedFromBackground() async {
        let client = RecordingFocusActivityClient()
        let manager = FocusLiveActivityManager(client: client, canStart: { false })
        await manager.enqueue(snapshot()).value
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testPersistedTimerProjectsPausedAndResumedTimeWithoutIncludingBreaks() {
        let defaults = UserDefaults.standard
        let keys = [FocusTimerStarter.startedAtKey, FocusTimerStarter.pausedAtKey, FocusTimerStarter.pausedSecondsKey, FocusTimerStarter.activeTaskTitleKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(1000.0, forKey: FocusTimerStarter.startedAtKey)
        defaults.set(1300.0, forKey: FocusTimerStarter.pausedAtKey)
        defaults.set(20.0, forKey: FocusTimerStarter.pausedSecondsKey)
        defaults.set("Exam preparation", forKey: FocusTimerStarter.activeTaskTitleKey)
        let paused = FocusTimerStarter.lockScreenSnapshot(at: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(paused?.elapsedSeconds, 280)
        XCTAssertEqual(paused?.taskTitle, "Exam preparation")
        XCTAssertEqual(paused?.isPaused, true)
        defaults.set(720.0, forKey: FocusTimerStarter.pausedSecondsKey)
        defaults.removeObject(forKey: FocusTimerStarter.pausedAtKey)
        let resumed = FocusTimerStarter.lockScreenSnapshot(at: Date(timeIntervalSince1970: 2050))
        XCTAssertEqual(resumed?.elapsedSeconds, 330)
        XCTAssertEqual(resumed?.timerStartedAt, Date(timeIntervalSince1970: 1720))
        XCTAssertEqual(paused?.sessionID, resumed?.sessionID)
        defaults.removeObject(forKey: FocusTimerStarter.startedAtKey)
        XCTAssertNil(FocusTimerStarter.lockScreenSnapshot())
    }

    func testInstalledAppEnablesLiveActivities() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool, true)
    }
}

@MainActor
private final class RecordingFocusActivityClient: FocusActivityClient {
    var isEnabled = true
    var activities: [FocusActivityReference] = []
    var requests: [FocusLockScreenSnapshot] = []
    var updates: [FocusLockScreenSnapshot] = []
    var ended: [String] = []
    var shouldFail = false
    func request(_ snapshot: FocusLockScreenSnapshot) throws {
        if shouldFail { throw NSError(domain: "TestActivity", code: 1) }
        requests.append(snapshot)
        activities.append(.init(id: UUID().uuidString, sessionID: snapshot.sessionID))
    }
    func update(_ activity: FocusActivityReference, snapshot: FocusLockScreenSnapshot) async {
        await Task.yield()
        updates.append(snapshot)
    }
    func end(_ activity: FocusActivityReference) async {
        await Task.yield()
        ended.append(activity.id)
        activities.removeAll { $0.id == activity.id }
    }
}
