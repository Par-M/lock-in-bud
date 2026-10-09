import Foundation
import XCTest
@testable import MyApp

@MainActor
final class MyAppTests: XCTestCase {
    func testAPIClientResolvesCachedAccountUUID() {
        let keychain = TestKeychain()
        let client = APIClient(keychain: keychain)
        XCTAssertEqual(client.userID, keychain.session?.user.id)
        keychain.clear()
        XCTAssertNil(client.userID)
    }

    func testStartingFocusResumesExistingTimerWithoutReplacingTask() throws {
        let keychain = TestKeychain()
        let userID = try XCTUnwrap(keychain.session?.user.id)
        let defaults = UserDefaults.standard
        let keys = [FocusTimerStarter.ownerKey, FocusTimerStarter.startedAtKey, FocusTimerStarter.activeTaskIDKey,
                    FocusTimerStarter.activeTaskTitleKey, FocusTimerStarter.activeCategoryKey]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) }
        }
        let taskID = UUID()
        defaults.set(userID.uuidString, forKey: FocusTimerStarter.ownerKey)
        defaults.set(123456.0, forKey: FocusTimerStarter.startedAtKey)
        defaults.set(taskID.uuidString, forKey: FocusTimerStarter.activeTaskIDKey)
        defaults.set("Original task", forKey: FocusTimerStarter.activeTaskTitleKey)
        defaults.set("Work", forKey: FocusTimerStarter.activeCategoryKey)
        FocusTimerStarter.startFocus(taskID: UUID(), title: "Another task", category: "Other", keychain: keychain)
        XCTAssertEqual(FocusTimerStarter.startedAt, 123456.0)
        XCTAssertEqual(FocusTimerStarter.activeTaskID, taskID)
        XCTAssertEqual(FocusTimerStarter.activeTaskTitle, "Original task")
        XCTAssertEqual(FocusTimerStarter.activeCategory, "Work")
    }

    func testPausedFocusExcludesBreaksAndAccountChangeClearsPauseState() {
        let defaults = UserDefaults.standard
        let keys = [FocusTimerStarter.ownerKey, FocusTimerStarter.startedAtKey, FocusTimerStarter.pausedAtKey, FocusTimerStarter.pausedSecondsKey, FocusTimerStarter.activeTaskIDKey, FocusTimerStarter.activeTaskTitleKey, FocusTimerStarter.activeCategoryKey]
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) } }
        defaults.set(1000.0, forKey: FocusTimerStarter.startedAtKey)
        defaults.set(1100.0, forKey: FocusTimerStarter.pausedAtKey)
        defaults.set(20.0, forKey: FocusTimerStarter.pausedSecondsKey)
        XCTAssertEqual(FocusTimerStarter.elapsedSeconds(at: 2000), 80)
        defaults.removeObject(forKey: FocusTimerStarter.pausedAtKey)
        defaults.set(920.0, forKey: FocusTimerStarter.pausedSecondsKey)
        XCTAssertEqual(FocusTimerStarter.elapsedSeconds(at: 2050), 130)
        FocusTimerStarter.synchronizeAccount(UUID())
        XCTAssertEqual(FocusTimerStarter.elapsedSeconds(at: 2050), 0)
        XCTAssertFalse(FocusTimerStarter.isPaused)
        XCTAssertEqual(defaults.double(forKey: FocusTimerStarter.pausedSecondsKey), 0)
    }

    func testCalendarPermissionHasFullAccessUsageDescription() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String
        XCTAssertFalse(description?.isEmpty ?? true, "Full calendar access needs a user-facing usage description")
    }

    func testLogoutEncodesOnlyCurrentRefreshToken() throws {
        let endpoint = AuthEndpoint.logout(refreshToken: "current-session-token")
        let body = try XCTUnwrap(endpoint.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(body)) as? [String: String])
        XCTAssertEqual(json, ["refresh_token": "current-session-token"])
        XCTAssertTrue(endpoint.requiresAuthentication)
        XCTAssertEqual(endpoint.method, .post)
    }

    func testTransientResponsesPreserveStatusAndBackendDetail() {
        for status in [429, 500, 503] {
            let error = NetworkError.response(status: status, data: Data(#"{"detail":"Try again later"}"#.utf8))
            guard case .serverError(let code, let detail) = error else {
                return XCTFail("Transient response incorrectly classified: \(error)")
            }
            XCTAssertEqual(code, status)
            XCTAssertEqual(detail, "Try again later")
        }
        guard case .httpStatus(502) = NetworkError.response(status: 502, data: Data("Bad gateway".utf8)) else {
            return XCTFail("Non-JSON failures must retain their HTTP status")
        }
    }

    func testUnauthorizedAndAlreadyDeletedResponsesRemainRecognizable() {
        let body = Data(#"{"detail":"Not found"}"#.utf8)
        guard case .unauthorized = NetworkError.response(status: 401, data: body) else {
            return XCTFail("401 must invalidate authentication")
        }
        guard case .httpStatus(404) = NetworkError.response(status: 404, data: body) else {
            return XCTFail("404 must remain recognizable by delete retries")
        }
    }

    func testValidationDetailsAreReadable() {
        let body = Data(#"{"detail":[{"msg":"End must follow start"},{"msg":"Invalid timezone"}]}"#.utf8)
        let error = NetworkError.response(status: 422, data: body)
        XCTAssertTrue(error.localizedDescription.contains("End must follow start; Invalid timezone"))
    }

    func testFocusSessionAndSummaryRangesAreIdentical() {
        let after = Date(timeIntervalSince1970: 1_800_000_000)
        let before = after.addingTimeInterval(86400)
        let sessions = FocusEndpoint.sessions(after: after, before: before).queryItems
        XCTAssertEqual(sessions, FocusEndpoint.summary(after: after, before: before).queryItems)
        XCTAssertEqual(sessions?.map(\.name), ["after", "before"])
        XCTAssertNil(FocusEndpoint.sessions(after: nil, before: nil).queryItems)
    }

    func testFocusOperationIDAndAtomicTimeFlagSurvivePersistence() throws {
        let operation = PendingFocusSession(
            id: UUID(), taskID: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_120), durationSeconds: 120, category: "Work"
        )
        let restored = try JSONDecoder().decode(PendingFocusSession.self, from: JSONEncoder().encode(operation))
        let firstPost = try JSONCoding.encoder.encode(operation.createPayload)
        let replay = try JSONCoding.encoder.encode(restored.createPayload)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: firstPost) as? [String: Any])
        let replayJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: replay) as? [String: Any])
        XCTAssertEqual(firstJSON["session_id"] as? String, operation.id.uuidString)
        XCTAssertEqual(replayJSON["session_id"] as? String, firstJSON["session_id"] as? String)
        XCTAssertEqual(firstJSON["record_task_time"] as? Bool, true)
        XCTAssertEqual(replayJSON["record_task_time"] as? Bool, true)
        XCTAssertEqual(replayJSON["task_id"] as? String, operation.taskID?.uuidString)
        XCTAssertEqual(replayJSON["duration_seconds"] as? Int, 120)
    }

    func testFocusQueueOnlyRetriesTransientOrAmbiguousFailures() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(FocusService.shouldQueue(NetworkError.httpStatus(status)))
            XCTAssertTrue(FocusService.shouldQueue(NetworkError.serverError(status: status, detail: "Retry")))
        }
        for status in [400, 401, 403, 404, 409, 422] {
            XCTAssertFalse(FocusService.shouldQueue(NetworkError.httpStatus(status)))
            XCTAssertFalse(FocusService.shouldQueue(NetworkError.serverError(status: status, detail: "Rejected")))
        }
        XCTAssertFalse(FocusService.shouldQueue(NetworkError.unauthorized))
        XCTAssertTrue(FocusService.shouldQueue(NetworkError.invalidResponse))
        XCTAssertTrue(FocusService.shouldQueue(NetworkError.decoding(NSError(domain: "test", code: 1))))
        for code in [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet, .cancelled] {
            XCTAssertTrue(FocusService.shouldQueue(URLError(code)))
        }
        XCTAssertFalse(FocusService.shouldQueue(URLError(.badURL)))
        XCTAssertFalse(FocusService.shouldQueue(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(FocusService.shouldQueue(NSError(domain: "validation", code: 1)))
    }

    func testMovedRepeatOverrideRendersAbsoluteDatesWithOriginalIdentity() throws {
        let calendar = Calendar.current
        let original = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let baseStart = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: original))
        let baseEnd = baseStart.addingTimeInterval(3600)
        let movedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: original))
        let movedStart = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: movedDay))
        let movedEnd = movedStart.addingTimeInterval(7200)
        var task = TaskItem(
            id: UUID(), userId: UUID(), title: "Moved occurrence", startAt: baseStart, endAt: baseEnd,
            priority: .medium, status: .pending,
            repeatWeekdays: [(calendar.component(.weekday, from: original) - 1 + 7) % 7],
            repeatEndsOn: original, isArchived: false, progressPercent: 0, createdAt: original, updatedAt: original
        )
        task.repeatOverrides = [OccurrenceDateKey.key(for: original): RepeatOverride(startAt: movedStart, endAt: movedEnd, completed: true)]
        XCTAssertTrue(CalendarEventItem.repeatingEvents(for: task, on: original).isEmpty)
        let moved = try XCTUnwrap(CalendarEventItem.repeatingEvents(for: task, on: movedDay).first)
        XCTAssertEqual(moved.start, movedStart)
        XCTAssertEqual(moved.end, movedEnd)
        XCTAssertEqual(moved.occurrenceDate, original)
        XCTAssertEqual(task.repeatOverrides?[OccurrenceDateKey.key(for: try XCTUnwrap(moved.occurrenceDate))]?.completed, true)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: movedDay))
        let carryover = try XCTUnwrap(CalendarEventItem.repeatingEvents(for: task, on: nextDay).first)
        XCTAssertEqual(carryover.id, moved.id)
        XCTAssertEqual(carryover.start, movedStart)
        XCTAssertEqual(carryover.end, movedEnd)
    }

    func testPlannerRequestsUseDateOnlyInRequestedTimezone() throws {
        let date = try XCTUnwrap(JSONCoding.parseISO8601("2026-10-05T01:30:00Z"))
        for (timezone, expected) in [("America/Los_Angeles", "2026-10-04"), ("Asia/Tokyo", "2026-10-05")] {
            let plan = ScheduleGenerateRequest(startDate: date, endDate: date, timezone: timezone, busyTimes: [])
            let daily = DailyRecommendationsRequest(timezone: timezone, startDate: date, endDate: date, busyTimes: [])
            for body in [try JSONCoding.encoder.encode(plan), try JSONCoding.encoder.encode(daily)] {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["start_date"] as? String, expected)
                XCTAssertEqual(json["end_date"] as? String, expected)
            }
        }
    }

    func testPendingFocusSessionsAreDurableAndAccountIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("PendingFocusSessions.json")
        let store = PendingFocusSessionStore(fileURL: file)
        let firstUser = UUID()
        let secondUser = UUID()
        let session = PendingFocusSession(taskID: nil, startedAt: Date(), endedAt: Date(), durationSeconds: 60, category: nil)
        store.save([session], userID: firstUser)
        XCTAssertEqual(PendingFocusSessionStore(fileURL: file).load(userID: firstUser).map(\.id), [session.id])
        XCTAssertTrue(store.load(userID: secondUser).isEmpty)
        store.save([], userID: secondUser)
        XCTAssertEqual(store.load(userID: firstUser).map(\.id), [session.id])
        try JSONEncoder().encode([session]).write(to: file)
        XCTAssertTrue(store.load(userID: UUID()).isEmpty, "Legacy unscoped sessions must not upload to an arbitrary account")
    }

    func testOvernightOccurrencePreservesCalendarDayOffsetAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 3)))
        let occurrenceDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let interval = CalendarEventItem.occurrenceInterval(start: start, end: end, on: occurrenceDay, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: interval.start), 7)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 8)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 3)
        XCTAssertEqual(interval.end.timeIntervalSince(interval.start), 3 * 3600)
    }
}

@MainActor
private final class TestKeychain: KeychainManaging {
    var session: AuthSession? = AuthSession(
        accessToken: "access", refreshToken: "refresh", tokenType: "bearer",
        user: User(id: UUID(), email: nil, name: nil, provider: "test")
    )

    func loadSession() -> AuthSession? { session }
    func save(_ session: AuthSession) { self.session = session }
    func clear() { session = nil }
}
