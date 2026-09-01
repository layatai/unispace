import Foundation
import XCTest

final class TwoProcessSimulationTests: XCTestCase {
    func testSimulatorHelpIsRunnableWithoutStartingNodes() throws {
        let result = try runSimulator(arguments: ["--help"], timeout: 10)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("run-two"))
    }

    private func runSimulator(arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try simulatorURL()
        process.arguments = arguments
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        for name in ["LANG", "LC_ALL", "LOGNAME", "TZ", "USER"] {
            if let value = inheritedEnvironment[name] { environment[name] = value }
        }
        environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("unispace-simulation-\(UUID().uuidString)-%p.profraw")
            .path
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let completed = expectation(description: "UniSpaceSimulation exits")
        process.terminationHandler = { _ in completed.fulfill() }

        try process.run()
        let waitResult = XCTWaiter.wait(for: [completed], timeout: timeout)
        if waitResult == .timedOut {
            process.terminate()
            waitForExit(process, timeout: 2)
        }
        let status = process.isRunning ? Int32.min : process.terminationStatus
        return ProcessResult(
            status: status,
            stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: (waitResult == .timedOut ? "UniSpaceSimulation exceeded \(timeout) seconds. " : "") +
                String(
                    decoding: error.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
        )
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
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
