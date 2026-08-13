import CoreGraphics
import Foundation
import XCTest
@testable import UniSpaceInfrastructure

final class NativeInputSmokeTests: XCTestCase {
    func testSignedProcessCanCreateAndStopInputEventTap() throws {
        guard FileManager.default.fileExists(atPath: Self.sentinelPath) else {
            throw XCTSkip("Run Scripts/test.sh --input-smoke for the signed native input check.")
        }
        guard CGPreflightListenEventAccess() else {
            return XCTFail("Grant Input Monitoring to the signed test process before running the input smoke test.")
        }
        guard CGPreflightPostEventAccess() else {
            return XCTFail("Grant Accessibility to the signed test process before running the input smoke test.")
        }
        let capture = CGEventInputCapture()

        try capture.start { _ in false }
        XCTAssertFalse(capture.isSuppressionEnabled)
        capture.stop()
    }

    private static var sentinelPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/input-smoke.enabled")
            .path
    }
}
