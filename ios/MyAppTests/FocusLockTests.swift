import XCTest
import FamilyControls
@testable import MyApp

@MainActor
final class FocusLockTests: XCTestCase {
    private func session(strict: Bool = false, count: Int = 0) -> FocusLockSession {
        FocusLockSession(id: "test", profile: "Study", strict: strict, selection: FamilyActivitySelection(), expiresAt: Date(timeIntervalSince1970: 200), exceptionCount: count)
    }
    func testStrictModeLimitsExceptionsButFlexibleModeDoesNot() {
        XCTAssertTrue(session(strict: true, count: 1).canRequestException)
        XCTAssertFalse(session(strict: true, count: 2).canRequestException)
        XCTAssertTrue(session(count: 10).canRequestException)
    }
    func testExpiredSessionHasNoBlockedApps() {
        XCTAssertTrue(session().blockedApplications(at: Date(timeIntervalSince1970: 200)).isEmpty)
    }
    func testSessionAndExceptionIdentitySurvivePersistence() throws {
        var original = session(strict: true, count: 1)
        original.exceptionID = "exception-1"
        original.exceptionUntil = Date(timeIntervalSince1970: 150)
        let restored = try JSONDecoder().decode(FocusLockSession.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.exceptionID, "exception-1")
        XCTAssertEqual(restored.exceptionUntil, original.exceptionUntil)
        XCTAssertTrue(restored.strict)
        XCTAssertEqual(restored.exceptionCount, 1)
    }
    func testOldCallbacksCannotEndNewSessionOrException() {
        var current = session(strict: true, count: 2)
        current.exceptionID = "new-exception"
        current.exceptionUntil = Date(timeIntervalSince1970: 150)
        XCTAssertNotNil(current.endingActivity("lock.session.old"))
        XCTAssertEqual(current.endingActivity("lock.exception.old")?.exceptionID, "new-exception")
        let relocked = current.endingActivity("lock.exception.new-exception")
        XCTAssertNil(relocked?.exceptionUntil)
        XCTAssertEqual(relocked?.exceptionCount, 2)
        XCTAssertNil(current.endingActivity("lock.session.test"))
    }
    func testMonitorExtensionIsEmbedded() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("FocusLockMonitor.appex")))
        let info = try XCTUnwrap(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        XCTAssertEqual(info["NSExtensionPointIdentifier"] as? String, "com.apple.deviceactivity.monitor-extension")
    }
}
