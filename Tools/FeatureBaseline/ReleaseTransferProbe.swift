import Foundation
import MachO
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

/// Exercises the exact archived framework binary, with delayed receiver ACKs.
/// No network, pasteboard, user files, or input devices are touched.
@main
struct ReleaseTransferProbe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path + "/"
        let loaded = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }
        for framework in ["UniSpaceDomain", "UniSpaceApplication", "UniSpaceInfrastructure"] {
            guard loaded.contains(where: { $0.hasPrefix(root + framework + ".framework/") }) else {
                throw ProbeFailure.wrongFramework
            }
        }
        try await ProbeDriver().run()
    }
}

private actor ProbeDriver {
    func run() async throws {
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(20))
            print("FAIL: transfer probe did not finish within twenty seconds")
            exit(1)
        }
        defer { watchdog.cancel() }
        let wire = ProbeWire()
        let transport = QoSFileTransferTransport(underlying: wire)
        let local = DeviceDescriptor(id: DeviceID(), name: "Probe")
        let workspace = WorkspaceSnapshot(id: WorkspaceID(), name: "Probe", localDeviceID: local.id, devices: [local])
        try await transport.start(localDevice: local, workspace: workspace, key: Data(repeating: 1, count: 32))
        @Sendable func envelope(_ message: FileTransferMessage, sender: DeviceID? = nil) -> FileTransferEnvelope {
            .init(workspaceID: workspace.id, senderDeviceID: sender ?? local.id, message: message)
        }
        for scenario in 0..<5 {
            let peer = DeviceID()
            let transfer = TransferID()
            let entry = TransferEntryID()
            try await transport.send(envelope(.chunk(.init(transferID: transfer, entryID: entry,
                offset: 0, data: Data(repeating: 1, count: 128 * 1_024)))), to: peer)
            let waiting = Task(priority: .utility) {
                try await transport.send(envelope(.entryComplete(.init(transferID: transfer, entryID: entry))), to: peer)
            }
            try await Task.sleep(for: .milliseconds(100))
            guard wire.completionCount == (scenario == 0 ? 0 : 1) else { throw ProbeFailure.prematureCompletion }
            switch scenario {
            case 0:
                wire.emit(.message(peer, envelope(.acknowledgement(.init(transferID: transfer,
                    entryID: entry, verifiedOffset: 128 * 1_024)), sender: peer)))
                try await waiting.value
                guard wire.completionCount == 1 else { throw ProbeFailure.missingCompletion }
            case 1:
                waiting.cancel()
                do { try await waiting.value; throw ProbeFailure.ignoredCancellation }
                catch is CancellationError {}
            case 2:
                try await transport.send(envelope(.cancellation(.init(transferID: transfer))), to: peer)
                do { try await waiting.value; throw ProbeFailure.ignoredCancellation }
                catch is CancellationError {}
            case 3:
                wire.emit(.disconnected(peer))
                do { try await waiting.value; throw ProbeFailure.ignoredCancellation }
                catch is CancellationError {}
            default:
                await transport.stop()
                do { try await waiting.value; throw ProbeFailure.ignoredCancellation }
                catch is CancellationError {}
            }
        }
        try await transferMixedBatch()
        print("PASS: delayed ACK, task/transfer cancellation, peer disconnect, and reset against release frameworks")
    }

    private func transferMixedBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UniSpace-release-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = DeviceDescriptor(id: DeviceID(), name: "Source", capabilities: [.fileTransferV1])
        let target = DeviceDescriptor(id: DeviceID(), name: "Target", capabilities: [.fileTransferV1])
        let id = WorkspaceID()
        let sourceWorkspace = WorkspaceSnapshot(id: id, name: "Probe", localDeviceID: source.id, devices: [source, target])
        let targetWorkspace = WorkspaceSnapshot(id: id, name: "Probe", localDeviceID: target.id, devices: [source, target])
        let outgoing = DelayedWire()
        let incoming = DelayedWire()
        outgoing.deliver = { [weak incoming] in incoming?.emit($0) }
        incoming.deliver = { [weak outgoing] in outgoing?.emit($0) }
        let receiverClipboard = await MainActor.run { ProbePasteboard() }
        let senderClipboard = await MainActor.run { ProbePasteboard() }
        let sender = FileTransferCoordinator(transport: QoSFileTransferTransport(underlying: outgoing),
            store: CheckpointingTransferStore(rootURL: root.appendingPathComponent("source-incoming")),
            sourceProvider: StreamingPersistentFileSourceProvider(rootURL: root.appendingPathComponent("source-outgoing")),
            pasteboard: senderClipboard)
        let receiver = FileTransferCoordinator(transport: QoSFileTransferTransport(underlying: incoming),
            store: CheckpointingTransferStore(rootURL: root.appendingPathComponent("target-incoming")),
            sourceProvider: StreamingPersistentFileSourceProvider(rootURL: root.appendingPathComponent("target-outgoing")),
            pasteboard: receiverClipboard)
        try await sender.start(localDevice: source, workspace: sourceWorkspace, key: Data(repeating: 1, count: 32))
        try await receiver.start(localDevice: target, workspace: targetWorkspace, key: Data(repeating: 1, count: 32))
        outgoing.emit(.connected(target.id))
        incoming.emit(.connected(source.id))
        try await Task.sleep(for: .milliseconds(50))
        let data = [Data(repeating: 9, count: 2 * 1_024 * 1_024), Data("Việt Nam".utf8), Data()]
        let names = ["binary.bin", "đặc-biệt.txt", "empty.txt"]
        let urls = try zip(names, data).map { name, content in
            let url = root.appendingPathComponent(name)
            try content.write(to: url)
            return url
        }
        let transfer = try await sender.sendFiles(urls, to: target.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await sender.snapshots().first(where: { $0.id == transfer })?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await sender.snapshots().first(where: { $0.id == transfer })?.state == .completed else {
            throw ProbeFailure.missingCompletion
        }
        let received = await receiverClipboard.urls
        guard received.count == names.count else { throw ProbeFailure.missingCompletion }
        for (name, content) in zip(names, data) {
            guard let url = received.first(where: { $0.lastPathComponent == name }),
                  try Data(contentsOf: url) == content else { throw ProbeFailure.missingCompletion }
        }
        await sender.stop()
        await receiver.stop()
        print("PASS: mixed file batch through release coordinators, sources, stores, and QoS")
    }
}

private enum ProbeFailure: Error { case prematureCompletion, missingCompletion, ignoredCancellation, wrongFramework }

@MainActor
private final class ProbePasteboard: FilePasteboard {
    var urls: [URL] = []
    func events() -> AsyncStream<PasteboardFileSelection> { AsyncStream { $0.finish() } }
    func publishFiles(_ urls: [URL], transferID: TransferID) { self.urls = urls }
}

private final class DelayedWire: FileTransferTransport, @unchecked Sendable {
    // Set before either coordinator starts; immutable during the probe.
    var deliver: (@Sendable (FileTransferTransportEvent) -> Void)?
    private let channel = AsyncStream<FileTransferTransportEvent>.makeStream()
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<FileTransferTransportEvent> { channel.stream }
    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        if case .acknowledgement = envelope.message { try await Task.sleep(for: .milliseconds(30)) }
        deliver?(.message(envelope.senderDeviceID, envelope))
    }
    func emit(_ event: FileTransferTransportEvent) { channel.continuation.yield(event) }
}

private final class ProbeWire: FileTransferTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var completions = 0
    private let channel = AsyncStream<FileTransferTransportEvent>.makeStream()
    var completionCount: Int { lock.withLock { completions } }
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {}
    func stop() async {}
    func events() -> AsyncStream<FileTransferTransportEvent> { channel.stream }
    func send(_ envelope: FileTransferEnvelope, to deviceID: DeviceID) async throws {
        if case .entryComplete = envelope.message { lock.withLock { completions += 1 } }
    }
    func emit(_ event: FileTransferTransportEvent) { channel.continuation.yield(event) }
}
