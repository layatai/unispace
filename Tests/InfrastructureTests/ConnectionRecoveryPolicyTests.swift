import Foundation
import XCTest
@testable import UniSpaceInfrastructure
import UniSpaceDomain

final class ConnectionRecoveryPolicyTests: XCTestCase {
    func testRetryScheduleOpensToOneAttemptPerMinute() {
        XCTAssertEqual(
            (0...7).map { ConnectionRetrySchedule.baseDelay(forAttempt: $0) },
            [1, 2, 4, 8, 15, 60, 60, 60]
        )
        XCTAssertEqual(ConnectionRetrySchedule.delay(forAttempt: 0, jitter: 0), 0.85)
        XCTAssertEqual(ConnectionRetrySchedule.delay(forAttempt: 5, jitter: 2), 69)
    }

    func testControllerIdentityStoreRoundTripsAndRemovesController() throws {
        let suite = "ConnectionRecoveryPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsControllerIdentityStore(defaults: defaults, keyPrefix: "test.controller")
        let workspaceID = WorkspaceID()
        let controllerID = DeviceID()

        XCTAssertNil(store.controllerID(for: workspaceID))
        store.setControllerID(controllerID, for: workspaceID)
        XCTAssertEqual(store.controllerID(for: workspaceID), controllerID)
        store.setControllerID(nil, for: workspaceID)
        XCTAssertNil(store.controllerID(for: workspaceID))
    }
}
