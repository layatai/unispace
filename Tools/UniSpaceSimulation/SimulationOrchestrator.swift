import Darwin
import Foundation

final class SimulationProcessClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var messages: [SimulationMessage] = []
    private var stderrData = Data()

    let name: String
    let configurationURL: URL

    init(name: String, executableURL: URL, configurationURL: URL) {
        self.name = name
        self.configurationURL = configurationURL
        process.executableURL = executableURL
        process.arguments = ["node", "--config", configurationURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.condition.withLock { self?.stderrData.append(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.condition.withLock { self?.condition.broadcast() }
        }
        try process.run()
    }

    func waitForReady(timeout: TimeInterval = 8) throws {
        do {
            _ = try waitForMessage(timeout: timeout) { $0.kind == "event" && $0.name == "ready" }
        } catch {
            throw exitedFailure(prefix: "\(name) did not become ready")
        }
    }

    func command(
        _ name: String,
        values: [String: String] = [:],
        timeout: TimeInterval = 15
    ) throws -> SimulationMessage {
        guard process.isRunning else { throw exitedFailure() }
        let command = SimulationCommand(id: UUID(), name: name, values: values)
        var data = try SimulationJSON.encoder.encode(command)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
        let response: SimulationMessage
        do {
            response = try waitForMessage(timeout: timeout) {
                $0.kind == "response" && $0.id == command.id
            }
        } catch {
            throw SimulationFailure.timeout("Timed out waiting for \(self.name) command \(name)")
        }
        guard response.ok == true else {
            let recentEvents = condition.withLock {
                messages.suffix(8).map { "\($0.name)=\($0.values)" }.joined(separator: ", ")
            }
            throw SimulationFailure.protocolFailure(
                "\(self.name) \(name) failed: \(response.values["error"] ?? "unknown error"). " +
                    "Recent events: \(recentEvents)"
            )
        }
        return response
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        closePipes()
    }

    func recentEvents() -> String {
        condition.withLock {
            messages.suffix(12).map { "\($0.name)=\($0.values)" }.joined(separator: ", ")
        }
    }

    func shutdown() {
        if process.isRunning { _ = try? command("shutdown", timeout: 5) }
        if process.isRunning { process.waitUntilExit() }
        closePipes()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            condition.withLock { condition.broadcast() }
            return
        }
        condition.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let message = try? SimulationJSON.decoder.decode(SimulationMessage.self, from: line) {
                    messages.append(message)
                }
            }
            condition.broadcast()
        }
    }

    private func waitForMessage(
        timeout: TimeInterval,
        matching predicate: (SimulationMessage) -> Bool
    ) throws -> SimulationMessage {
        let deadline = Date().addingTimeInterval(timeout)
        return try condition.withLock {
            while true {
                if let index = messages.firstIndex(where: predicate) {
                    return messages.remove(at: index)
                }
                if !process.isRunning { throw exitedFailure() }
                guard condition.wait(until: deadline) else {
                    throw SimulationFailure.timeout("Timed out waiting for \(name)")
                }
            }
        }
    }

    private func exitedFailure(prefix: String? = nil) -> SimulationFailure {
        let stderr = condition.withLock {
            String(data: stderrData, encoding: .utf8) ?? ""
        }
        return .childExited("\(prefix ?? "\(name) exited unexpectedly"). \(stderr)")
    }

    private func closePipes() {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
    }
}

final class SimulationOrchestrator {
    private let executableURL: URL
    private let samples: Int
    private let keepArtifacts: URL?
    private let thresholds = SimulationThresholds.ci
    private let root: URL
    private let configA: URL
    private let configB: URL
    private let nodeAOwnsControlConnection: Bool
    private var nodeA: SimulationProcessClient
    private var nodeB: SimulationProcessClient
    private var conditions: [ConditionReport] = []
    private var steps: [SimulationStepReport] = []
    private var failures: [String] = []
    private var nodePIDs: [Int32] = []

    init(executableURL: URL, samples: Int, keepArtifacts: URL?) throws {
        self.executableURL = executableURL
        self.samples = max(samples, 50)
        self.keepArtifacts = keepArtifacts
        root = keepArtifacts ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("UniSpaceSimulation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let ids = (UUID(), UUID(), UUID(), UUID(), UUID())
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let portsA = try Self.allocatePorts()
        let portsB = try Self.allocatePorts(excluding: Set(Self.portValues(portsA)))
        let firstOwns = ids.0.uuidString < ids.1.uuidString
        nodeAOwnsControlConnection = firstOwns
        let stateA = root.appendingPathComponent("node-a", isDirectory: true)
        let stateB = root.appendingPathComponent("node-b", isDirectory: true)
        configA = root.appendingPathComponent("node-a.json")
        configB = root.appendingPathComponent("node-b.json")
        let first = SimulationNodeConfiguration(
            name: "node-a",
            deviceID: ids.0,
            displayID: ids.3,
            peerName: "node-b",
            peerDeviceID: ids.1,
            peerDisplayID: ids.4,
            workspaceID: ids.2,
            workspaceKeyBase64: key.base64EncodedString(),
            stateDirectory: stateA.path,
            pasteboardName: "com.layatai.unispace.simulation.\(ids.0.uuidString)",
            ports: portsA,
            peerPorts: portsB,
            ownsControlConnection: firstOwns
        )
        let second = SimulationNodeConfiguration(
            name: "node-b",
            deviceID: ids.1,
            displayID: ids.4,
            peerName: "node-a",
            peerDeviceID: ids.0,
            peerDisplayID: ids.3,
            workspaceID: ids.2,
            workspaceKeyBase64: key.base64EncodedString(),
            stateDirectory: stateB.path,
            pasteboardName: "com.layatai.unispace.simulation.\(ids.1.uuidString)",
            ports: portsB,
            peerPorts: portsA,
            ownsControlConnection: !firstOwns
        )
        try Self.writeConfiguration(first, to: configA)
        try Self.writeConfiguration(second, to: configB)
        nodeA = SimulationProcessClient(name: "node-a", executableURL: executableURL, configurationURL: configA)
        nodeB = SimulationProcessClient(name: "node-b", executableURL: executableURL, configurationURL: configB)
    }

    deinit {
        nodeA.terminate()
        nodeB.terminate()
    }

    func runAll() throws -> SimulationReport {
        defer { cleanup() }
        try step("start-two-nodes") {
            try startNodes()
            try waitForConnections()
        }

        var activationSamples: [Double] = []
        try step("activation-and-keyboard") {
            _ = try nodeB.command("beginMetrics", values: ["condition": "idle"])
            _ = try nodeA.command("claim")
            Thread.sleep(forTimeInterval: 0.1)
            for _ in 0..<20 {
                let response: SimulationMessage
                do {
                    response = try nodeA.command("activate")
                } catch {
                    throw SimulationFailure.protocolFailure(
                        "\(error.localizedDescription); receiver events: \(nodeB.recentEvents())"
                    )
                }
                let nanos = UInt64(response.values["latencyNanos"] ?? "0") ?? 0
                activationSamples.append(Double(nanos) / 1_000_000)
                _ = try nodeA.command("deactivate")
                Thread.sleep(forTimeInterval: 0.1)
            }
            _ = try nodeA.command("activate")
            _ = try nodeA.command("keyBatch", values: ["count": "100"])
            let keyboard = try metrics(from: nodeB, condition: "idle").keyboard
            if percentile(activationSamples, 0.95) > thresholds.activationMilliseconds {
                failures.append("Activation p95 exceeded \(thresholds.activationMilliseconds) ms")
            }
            if keyboard.p95Milliseconds > thresholds.keyboardP95Milliseconds ||
                keyboard.maximumMilliseconds > thresholds.maximumLatencyMilliseconds {
                failures.append("Reliable keyboard latency exceeded its threshold")
            }
        }

        let idle = try measurePointer(condition: "idle")
        conditions.append(evaluate(condition: "idle", report: idle, idleP95: nil))

        try step("clipboard-round-trip") {
            let sent = try nodeA.command("clipboard", values: ["value": "simulation-clipboard"])
                .values["value"] ?? ""
            let started = UInt64(sent.split(separator: "|").first ?? "0") ?? 0
            try wait(timeout: 3, description: "clipboard delivery") {
                try self.nodeB.command("clipboardRead").values["value"] == sent
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if elapsed > thresholds.clipboardMilliseconds {
                failures.append("Clipboard delivery took \(elapsed) ms")
            }
        }

        _ = try nodeA.command("clipboardChurnStart")
        let clipboard = try measurePointer(condition: "clipboard")
        _ = try nodeA.command("clipboardChurnStop")
        conditions.append(evaluate(
            condition: "clipboard",
            report: clipboard,
            idleP95: idle.visible.p95Milliseconds
        ))

        try step("finder-multi-file") {
            let sent = try nodeA.command("copyGenerated", values: [
                "byteCount": "4096",
                "fileCount": "2",
            ])
            try waitForCompletedTransfer(on: nodeA, timeout: 10)
            let received = try nodeB.command("filesRead")
            guard sent.values["digests"] == received.values["digests"] else {
                throw SimulationFailure.protocolFailure("Multi-file Finder digests do not match")
            }
        }

        try step("file-load-and-recovery") {
            _ = try nodeA.command("copyGenerated", values: [
                "byteCount": String(96 * 1_024 * 1_024),
                "fileCount": "1",
            ], timeout: 30)
            try wait(timeout: 5, description: "large transfer start") {
                try self.nodeA.command("transferStatus").values["states"]?.contains("transferring") == true
            }
            let fileLoad = try measurePointer(condition: "file")
            conditions.append(evaluate(
                condition: "file",
                report: fileLoad,
                idleP95: idle.visible.p95Milliseconds
            ))

            let recoveryStarted = DispatchTime.now().uptimeNanoseconds
            nodeB.terminate()
            try startNodeB()
            nodePIDs.append(nodeB.processIdentifier)
            _ = try nodeA.command("reconnect")
            try waitForConnections()
            try waitForCompletedTransfer(on: nodeA, timeout: 20)
            let reconnect = Double(DispatchTime.now().uptimeNanoseconds - recoveryStarted) / 1_000_000
            if reconnect > thresholds.reconnectMilliseconds {
                failures.append("Recovery took \(reconnect) ms")
            }
        }

        try step("post-recovery-control") {
            _ = try nodeA.command("claim")
            Thread.sleep(forTimeInterval: 0.1)
            _ = try nodeA.command("activate")
            _ = try nodeB.command("beginMetrics", values: ["condition": "recovered"])
            _ = try nodeA.command("moveBatch", values: ["count": "120", "intervalMicros": "8333"])
            let recovered = try metrics(from: nodeB, condition: "recovered")
            guard recovered.visible.count > 0 else {
                throw SimulationFailure.protocolFailure("No pointer input arrived after recovery")
            }
        }

        for condition in conditions where !condition.passed {
            failures.append(contentsOf: condition.failures)
        }
        let report = SimulationReport(
            passed: failures.isEmpty,
            samplesPerCondition: samples,
            conditions: conditions,
            steps: steps,
            failures: failures,
            nodePIDs: nodePIDs,
            artifactDirectory: keepArtifacts?.path
        )
        return report
    }

    func runShell() throws {
        try startNodes()
        try waitForConnections()
        FileHandle.standardError.write(Data("Two nodes ready. Type 'help' for commands.\n".utf8))
        while let line = readLine() {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard let command = parts.first else { continue }
            if command == "quit" { break }
            if command == "help" {
                print("status | control | move [count] | clipboard <text> | copy <bytes> | kill b | restart b | metrics <condition> | quit")
                continue
            }
            do {
                switch command {
                case "status": print(try nodeA.command("status").values)
                case "control":
                    _ = try nodeA.command("claim")
                    print(try nodeA.command("activate").values)
                case "move":
                    print(try nodeA.command("moveBatch", values: ["count": parts.dropFirst().first ?? "120"]).values)
                case "clipboard":
                    print(try nodeA.command("clipboard", values: ["value": parts.dropFirst().joined(separator: " ")]).values)
                case "copy":
                    print(try nodeA.command("copyGenerated", values: ["byteCount": parts.dropFirst().first ?? "1048576"]).values)
                case "kill": nodeB.terminate()
                case "restart":
                    try startNodeB()
                    _ = try nodeA.command("reconnect")
                case "metrics": print(try nodeB.command("metrics", values: ["condition": parts.dropFirst().first ?? "idle"]).values)
                default: print("Unknown command")
                }
            } catch { print("error: \(error.localizedDescription)") }
        }
        cleanup()
    }

    private func startNodes() throws {
        if nodeAOwnsControlConnection {
            try startNodeB()
            try startNodeA()
        } else {
            try startNodeA()
            try startNodeB()
        }
        nodePIDs = [nodeA.processIdentifier, nodeB.processIdentifier]
    }

    private func startNodeA() throws {
        try startWithRetry(name: "node-a", configurationURL: configA) { self.nodeA = $0 }
    }

    private func startNodeB() throws {
        try startWithRetry(name: "node-b", configurationURL: configB) { self.nodeB = $0 }
    }

    private func startWithRetry(
        name: String,
        configurationURL: URL,
        assign: (SimulationProcessClient) -> Void
    ) throws {
        var lastError: Error?
        for _ in 0..<3 {
            let client = SimulationProcessClient(
                name: name,
                executableURL: executableURL,
                configurationURL: configurationURL
            )
            assign(client)
            do {
                try client.start()
                try client.waitForReady(timeout: 12)
                return
            } catch {
                lastError = error
                client.terminate()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        throw lastError ?? SimulationFailure.childExited("\(name) could not start")
    }

    private func waitForConnections() throws {
        try wait(timeout: 8, description: "all protocol connections") {
            let first = try self.nodeA.command("status")
            let second = try self.nodeB.command("status")
            return first.values["controlConnected"] == "true" &&
                second.values["controlConnected"] == "true" &&
                first.values["fileConnections"] == "1" &&
                second.values["fileConnections"] == "1" &&
                first.values["clipboardConnections"] == "1" &&
                second.values["clipboardConnections"] == "1"
        }
    }

    private func measurePointer(
        condition: String
    ) throws -> (wire: LatencySummary, visible: LatencySummary, keyboard: LatencySummary) {
        _ = try nodeB.command("beginMetrics", values: ["condition": "\(condition)-warmup"])
        _ = try nodeA.command("moveBatch", values: ["count": "100", "intervalMicros": "8333"])
        _ = try nodeB.command("beginMetrics", values: ["condition": condition])
        var delivered = 0
        var attempts = 0
        while delivered < samples, attempts < 4 {
            _ = try nodeA.command("moveBatch", values: [
                "count": String(samples * 2),
                "intervalMicros": "8333",
            ], timeout: 30)
            let report = try metrics(from: nodeB, condition: condition)
            delivered = report.visible.count
            attempts += 1
        }
        guard delivered >= samples else {
            throw SimulationFailure.protocolFailure(
                "Only \(delivered) pointer samples arrived for \(condition); expected \(samples)"
            )
        }
        return try metrics(from: nodeB, condition: condition)
    }

    private func metrics(
        from node: SimulationProcessClient,
        condition: String
    ) throws -> (wire: LatencySummary, visible: LatencySummary, keyboard: LatencySummary) {
        let response = try node.command("metrics", values: ["condition": condition])
        func decode(_ key: String) throws -> LatencySummary {
            guard let string = response.values[key], let data = string.data(using: .utf8) else {
                throw SimulationFailure.protocolFailure("Missing \(key) metrics")
            }
            return try SimulationJSON.decoder.decode(LatencySummary.self, from: data)
        }
        return (try decode("wire"), try decode("visible"), try decode("keyboard"))
    }

    private func evaluate(
        condition: String,
        report: (wire: LatencySummary, visible: LatencySummary, keyboard: LatencySummary),
        idleP95: Double?
    ) -> ConditionReport {
        var failures: [String] = []
        let allowedP95: Double
        if let idleP95 {
            allowedP95 = max(
                idleP95 * thresholds.loadedP95Factor,
                idleP95 + thresholds.loadedP95DeltaMilliseconds
            )
        } else {
            allowedP95 = thresholds.idleP95Milliseconds
        }
        if report.visible.p95Milliseconds > allowedP95 {
            failures.append("\(condition) visible p95 \(report.visible.p95Milliseconds) ms > \(allowedP95) ms")
        }
        for (name, summary) in [("wire", report.wire), ("visible", report.visible)] {
            if summary.maximumMilliseconds > thresholds.maximumLatencyMilliseconds {
                failures.append("\(condition) \(name) max \(summary.maximumMilliseconds) ms > 50 ms")
            }
            if summary.maximumGapMilliseconds > thresholds.maximumLatencyMilliseconds {
                failures.append("\(condition) \(name) stall \(summary.maximumGapMilliseconds) ms > 50 ms")
            }
        }
        return ConditionReport(
            name: condition,
            wire: report.wire,
            visible: report.visible,
            passed: failures.isEmpty,
            failures: failures
        )
    }

    private func waitForCompletedTransfer(on node: SimulationProcessClient, timeout: TimeInterval) throws {
        try wait(timeout: timeout, description: "file transfer completion") {
            let states = try node.command("transferStatus").values["states"] ?? ""
            return states.split(separator: ",").last == "completed"
        }
    }

    private func wait(
        timeout: TimeInterval,
        description: String,
        predicate: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try predicate() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SimulationFailure.timeout("Timed out waiting for \(description)")
    }

    private func step(_ name: String, operation: () throws -> Void) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try operation()
            steps.append(.init(
                name: name,
                passed: true,
                durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                detail: "passed"
            ))
        } catch {
            steps.append(.init(
                name: name,
                passed: false,
                durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                detail: error.localizedDescription
            ))
            throw error
        }
    }

    private func cleanup() {
        nodeA.shutdown()
        nodeB.shutdown()
        guard keepArtifacts == nil else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeConfiguration(
        _ configuration: SimulationNodeConfiguration,
        to url: URL
    ) throws {
        try SimulationJSON.encoder.encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func allocatePorts(excluding: Set<UInt16> = []) throws -> SimulationPorts {
        var used = excluding
        func next(socketType: Int32) throws -> UInt16 {
            for _ in 0..<20 {
                let port = try availablePort(socketType: socketType)
                if used.insert(port).inserted { return port }
            }
            throw SimulationFailure.invalidConfiguration("Could not allocate unique loopback ports")
        }
        return try SimulationPorts(
            control: next(socketType: SOCK_STREAM),
            quic: next(socketType: SOCK_DGRAM),
            realtime: next(socketType: SOCK_DGRAM),
            files: next(socketType: SOCK_STREAM),
            clipboard: next(socketType: SOCK_STREAM)
        )
    }

    private static func portValues(_ ports: SimulationPorts) -> [UInt16] {
        [ports.control, ports.quic, ports.realtime, ports.files, ports.clipboard]
    }

    private static func availablePort(socketType: Int32) throws -> UInt16 {
        let descriptor = socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else {
            throw SimulationFailure.invalidConfiguration("Could not create port-allocation socket")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw SimulationFailure.invalidConfiguration("Could not bind port-allocation socket")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else {
            throw SimulationFailure.invalidConfiguration("Could not resolve allocated port")
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
