import Foundation
import XCTest

final class TwoProcessSimulationTests: XCTestCase {
    func testTwoProcessSimulationMeetsProtocolLatencyAndRecoveryGates() throws {
        let artifacts = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniSpaceSimulationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let result = try runSimulator(
            arguments: [
                "run-two", "--scenario", "all", "--samples", "500", "--json",
                "--keep-artifacts", artifacts.path,
            ],
            timeout: 120
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let report = try JSONDecoder().decode(SimulationReportFixture.self, from: result.stdout)
        XCTAssertTrue(report.passed, report.failures.joined(separator: "; "))
        XCTAssertEqual(Set(report.nodePIDs).count, report.nodePIDs.count)
        XCTAssertGreaterThanOrEqual(report.nodePIDs.count, 3, "Recovery must launch a replacement node")
        XCTAssertEqual(Set(report.conditions.map(\.name)), ["idle", "clipboard", "file"])
        for condition in report.conditions {
            XCTAssertTrue(condition.passed, condition.failures.joined(separator: "; "))
            XCTAssertGreaterThanOrEqual(condition.visible.count, 500)
            XCTAssertLessThanOrEqual(condition.visible.maximumMilliseconds, 50)
            XCTAssertLessThanOrEqual(condition.visible.maximumGapMilliseconds, 50)
        }
        XCTAssertTrue(report.steps.allSatisfy(\.passed))
        for name in ["node-a.json", "node-b.json"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: artifacts.appendingPathComponent(name).path
            )
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
        }
    }

    func testSimulatorHelpIsRunnableWithoutStartingNodes() throws {
        let result = try runSimulator(arguments: ["--help"], timeout: 10)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("run-two"))
    }

    func testSimulatorRejectsUnknownScenario() throws {
        let result = try runSimulator(
            arguments: ["run-two", "--scenario", "unknown"],
            timeout: 10
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Only --scenario all is currently supported"))
    }

    private func runSimulator(arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try simulatorURL()
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let completed = expectation(description: "UniSpaceSimulation exits")
        process.terminationHandler = { _ in completed.fulfill() }

        try process.run()
        wait(for: [completed], timeout: timeout)
        if process.isRunning { process.terminate() }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private func simulatorURL() throws -> URL {
        if let products = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            let candidate = URL(fileURLWithPath: products).appendingPathComponent("UniSpaceSimulation")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("UniSpaceSimulation")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "TwoProcessSimulationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "UniSpaceSimulation executable was not built"]
            )
        }
        return executable
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

private struct SimulationReportFixture: Decodable {
    let passed: Bool
    let conditions: [ConditionFixture]
    let steps: [StepFixture]
    let failures: [String]
    let nodePIDs: [Int32]
}

private struct ConditionFixture: Decodable {
    let name: String
    let visible: LatencyFixture
    let passed: Bool
    let failures: [String]
}

private struct LatencyFixture: Decodable {
    let count: Int
    let maximumMilliseconds: Double
    let maximumGapMilliseconds: Double
}

private struct StepFixture: Decodable {
    let passed: Bool
}
