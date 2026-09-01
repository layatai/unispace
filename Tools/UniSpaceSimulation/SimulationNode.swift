import AppKit
import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain
import UniSpaceInfrastructure

actor SimulationNodeRuntime {
    private let configuration: SimulationNodeConfiguration
    private let localID: DeviceID
    private let peerID: DeviceID
    private let peerDisplay: DisplayDescriptor
    private let transport: NetworkPeerTransport
    private let coordinator: ControlSessionCoordinator
    private let clipboardCoordinator: ClipboardCoordinator
    private let fileCoordinator: FileTransferCoordinator
    private let qosFileTransport: QoSFileTransferTransport
    private let pasteboard: SimulationPasteboardBox
    private let metrics: SimulationMetricsRecorder
    private let injector: SimulationInputInjector
    private let emitter: SimulationLineEmitter
    private var peerEventsTask: Task<Void, Never>?
    private var clipboardChurnTask: Task<Void, Never>?
    private var controlConnected = false
    private var stopping = false

    init(configuration: SimulationNodeConfiguration, emitter: SimulationLineEmitter) async throws {
        self.configuration = configuration
        self.emitter = emitter
        localID = DeviceID(rawValue: configuration.deviceID)
        peerID = DeviceID(rawValue: configuration.peerDeviceID)
        metrics = SimulationMetricsRecorder()
        injector = SimulationInputInjector(recorder: metrics)

        guard let controlPort = NWEndpoint.Port(rawValue: configuration.ports.control),
              let directControlPort = NWEndpoint.Port(rawValue: configuration.peerPorts.control),
              let quicPort = NWEndpoint.Port(rawValue: configuration.ports.quic),
              let directQUICPort = NWEndpoint.Port(rawValue: configuration.peerPorts.quic),
              let realtimePort = NWEndpoint.Port(rawValue: configuration.ports.realtime),
              let directRealtimePort = NWEndpoint.Port(rawValue: configuration.peerPorts.realtime),
              let filePort = NWEndpoint.Port(rawValue: configuration.ports.files),
              let directFilePort = NWEndpoint.Port(rawValue: configuration.peerPorts.files),
              let clipboardPort = NWEndpoint.Port(rawValue: configuration.ports.clipboard),
              let directClipboardPort = NWEndpoint.Port(rawValue: configuration.peerPorts.clipboard) else {
            throw SimulationFailure.invalidConfiguration("Invalid simulation port allocation")
        }

        transport = NetworkPeerTransport(
            listenPort: controlPort,
            directPort: directControlPort,
            quicListenPort: quicPort,
            directQUICPort: directQUICPort,
            realtimeListenPort: realtimePort,
            directRealtimePort: directRealtimePort,
            pointerListenPort: realtimePort,
            directPointerPort: directRealtimePort,
            enableBonjour: false,
            enableQUIC: false,
            enableRealtime: true,
            authenticationTimeout: 3
        )
        coordinator = ControlSessionCoordinator(
            localDeviceID: localID,
            workspaceID: WorkspaceID(rawValue: configuration.workspaceID),
            capture: SimulationInputCapture(),
            injector: injector,
            transport: transport
        )

        let clipboardTransport = NetworkClipboardTransport(
            listenPort: clipboardPort,
            directPort: directClipboardPort,
            enableBonjour: false,
            listenerRetryDelays: [0.1, 0.2, 0.5]
        )
        pasteboard = await SimulationPasteboardBox(name: configuration.pasteboardName)
        let clipboardService = await pasteboard.makeClipboardService()
        clipboardCoordinator = ClipboardCoordinator(
            transport: clipboardTransport,
            clipboard: clipboardService
        )

        let rawFileTransport = NetworkFileTransferTransport(
            listenPort: filePort,
            directPort: directFilePort,
            enableBonjour: false
        )
        let qosConfiguration = FileTransferQoSConfiguration(
            throughputChunkSize: 256 * 1_024,
            interactiveChunkSize: 64 * 1_024,
            degradedChunkSize: 64 * 1_024,
            throughputOutstandingBytes: 8 * 1_024 * 1_024,
            interactiveOutstandingBytes: 512 * 1_024,
            degradedOutstandingBytes: 256 * 1_024,
            interactiveBytesPerSecond: 8 * 1_024 * 1_024,
            degradedBytesPerSecond: 2 * 1_024 * 1_024,
            degradedLatencyMilliseconds: 30
        )
        qosFileTransport = QoSFileTransferTransport(
            underlying: rawFileTransport,
            configuration: qosConfiguration
        )

        let root = URL(fileURLWithPath: configuration.stateDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incoming = CheckpointingTransferStore(
            rootURL: root.appendingPathComponent("incoming", isDirectory: true)
        )
        let outgoing = StreamingPersistentFileSourceProvider(
            rootURL: root.appendingPathComponent("outgoing", isDirectory: true)
        )
        let filePasteboard = await pasteboard.makeFilePasteboard()
        fileCoordinator = FileTransferCoordinator(
            transport: qosFileTransport,
            store: incoming,
            sourceProvider: outgoing,
            pasteboard: filePasteboard
        )

        peerDisplay = DisplayDescriptor(
            id: DisplayID(rawValue: configuration.peerDisplayID),
            deviceID: peerID,
            name: "\(configuration.peerName) Display",
            frame: .init(x: 0, y: 0, width: 1_920, height: 1_080),
            scaleFactor: 2,
            isMain: true
        )
    }

    func start() async throws {
        guard let key = Data(base64Encoded: configuration.workspaceKeyBase64), key.count >= 32 else {
            throw SimulationFailure.invalidConfiguration("Invalid workspace key")
        }
        let workspace = makeWorkspace()
        let local = try localDevice()

        peerEventsTask = Task { [weak self, transport] in
            for await event in transport.events() {
                guard !Task.isCancelled else { return }
                await self?.handlePeerEvent(event)
            }
        }
        try await transport.start(localDevice: local, workspace: workspace, key: key)
        transport.updateConnectionPolicy(
            configuration.ownsControlConnection
                ? PeerConnectionPolicy(outboundPeerIDs: [peerID])
                : .passive
        )

        try await clipboardCoordinator.start(localDevice: local, workspace: workspace, key: key)
        await clipboardCoordinator.setSharingEnabled(true)
        await clipboardCoordinator.setAutomaticDestination(peerID)

        try await fileCoordinator.start(localDevice: local, workspace: workspace, key: key)
        await fileCoordinator.setAutomaticDestination(peerID)

        try await waitForListeners()
        emitter.send(.event("ready", values: ["node": configuration.name]))
    }

    func handle(_ command: SimulationCommand) async -> Bool {
        do {
            let values = try await execute(command)
            emitter.send(.response(to: command, ok: true, values: values))
        } catch {
            emitter.send(.response(
                to: command,
                ok: false,
                values: ["error": error.localizedDescription]
            ))
        }
        return command.name != "shutdown"
    }

    private func execute(_ command: SimulationCommand) async throws -> [String: String] {
        switch command.name {
        case "status":
            let state = await coordinator.currentState()
            return [
                "controlConnected": String(controlConnected),
                "controlState": String(describing: state),
                "fileConnections": String((await fileCoordinator.connectedDeviceIDs()).count),
                "clipboardConnections": String((await clipboardCoordinator.connectedDeviceIDs()).count),
            ]
        case "claim":
            let epoch = await coordinator.makeLocalController()
            try await transport.send(
                ControlEnvelope(message: .controllerClaim(epoch)),
                to: peerID
            )
            return ["generation": String(epoch.generation)]
        case "activate":
            let started = DispatchTime.now().uptimeNanoseconds
            try await coordinator.activate(
                target: peerID,
                displayID: peerDisplay.id,
                entryEdge: .left,
                normalizedPosition: 0.5,
                targetCapabilities: try peerDevice().capabilities,
                targetPlatform: .macOS,
                requiresActivationConfirmation: true
            )
            await qosFileTransport.updateControlQuality(.init(
                isControlActive: true,
                activePeerID: peerID,
                latencyMilliseconds: nil
            ))
            return ["latencyNanos": String(DispatchTime.now().uptimeNanoseconds - started)]
        case "deactivate":
            await coordinator.deactivateCurrentSession()
            await qosFileTransport.updateControlQuality(.idle)
            return [:]
        case "beginMetrics":
            let condition = command.values["condition"] ?? "idle"
            metrics.begin(condition)
            return ["condition": condition]
        case "metrics":
            let condition = command.values["condition"] ?? "idle"
            let report = metrics.report(condition)
            return [
                "wire": String(data: try SimulationJSON.encoder.encode(report.wire), encoding: .utf8)!,
                "visible": String(data: try SimulationJSON.encoder.encode(report.visible), encoding: .utf8)!,
                "keyboard": String(
                    data: try SimulationJSON.encoder.encode(metrics.keyboardReport(condition)),
                    encoding: .utf8
                )!,
            ]
        case "moveBatch":
            let count = Int(command.values["count"] ?? "1000") ?? 1_000
            let intervalMicroseconds = UInt64(command.values["intervalMicros"] ?? "8333") ?? 8_333
            emitter.send(.event("moveBatchStarted", values: ["count": String(count)]))
            for index in 0..<count {
                let capturedAt = DispatchTime.now().uptimeNanoseconds
                _ = await coordinator.handleCaptured(.pointerMove(
                    deltaX: 1,
                    deltaY: index.isMultiple(of: 2) ? 1 : -1,
                    absoluteX: Double(index),
                    absoluteY: Double(capturedAt)
                ))
                if index > 0, index.isMultiple(of: 100) {
                    emitter.send(.event("moveBatchProgress", values: ["captured": String(index)]))
                }
                try await Task.sleep(for: .microseconds(Int64(intervalMicroseconds)))
            }
            emitter.send(.event("moveBatchFlushing", values: ["captured": String(count)]))
            await coordinator.flushPendingInput()
            emitter.send(.event("moveBatchCompleted", values: ["captured": String(count)]))
            return ["captured": String(count)]
        case "keyBatch":
            let count = Int(command.values["count"] ?? "100") ?? 100
            for index in 0..<count {
                _ = await coordinator.handleCaptured(.key(
                    code: UInt16(index % 64),
                    isDown: index.isMultiple(of: 2),
                    isRepeat: false
                ))
            }
            await coordinator.flushPendingInput()
            return ["captured": String(count)]
        case "clipboard":
            let value = command.values["value"] ?? ""
            let stamped = "\(DispatchTime.now().uptimeNanoseconds)|\(value)"
            await writeClipboard(stamped)
            return ["value": stamped]
        case "clipboardRead":
            return ["value": await readClipboard() ?? ""]
        case "clipboardChurnStart":
            startClipboardChurn()
            return [:]
        case "clipboardChurnStop":
            clipboardChurnTask?.cancel()
            clipboardChurnTask = nil
            return [:]
        case "copyGenerated":
            let byteCount = Int(command.values["byteCount"] ?? "1048576") ?? 1_048_576
            let fileCount = Int(command.values["fileCount"] ?? "1") ?? 1
            let urls = try generatedFiles(byteCount: byteCount, fileCount: fileCount)
            await writeFileSelection(urls)
            return [
                "paths": urls.map(\.path).joined(separator: "\u{1F}"),
                "digests": try urls.map(SimulationFiles.digest).joined(separator: ","),
            ]
        case "filesRead":
            let urls = await readFileSelection()
            return [
                "paths": urls.map(\.path).joined(separator: "\u{1F}"),
                "digests": try urls.map(SimulationFiles.digest).joined(separator: ","),
            ]
        case "transferStatus":
            let snapshots = await fileCoordinator.snapshots()
            return [
                "states": snapshots.map { $0.state.rawValue }.joined(separator: ","),
                "progress": snapshots.map { String($0.transferredByteCount) }.joined(separator: ","),
            ]
        case "reconnect":
            transport.reconnect(to: peerID)
            await clipboardCoordinator.setAutomaticDestination(peerID)
            await fileCoordinator.setAutomaticDestination(peerID)
            return [:]
        case "shutdown":
            await stop()
            return [:]
        default:
            throw SimulationFailure.protocolFailure("Unknown command: \(command.name)")
        }
    }

    private func handlePeerEvent(_ event: PeerEvent) async {
        switch event {
        case let .connected(deviceID):
            guard deviceID == peerID else { return }
            controlConnected = true
            emitter.send(.event("controlConnected", values: ["peer": deviceID.description]))
        case let .disconnected(deviceID):
            guard deviceID == peerID else { return }
            controlConnected = false
            await coordinator.peerDisconnected(deviceID)
            emitter.send(.event("controlDisconnected", values: ["peer": deviceID.description]))
        case let .control(source, envelope):
            await handleControl(envelope.message, from: source)
        case let .input(source, frame):
            metrics.recordWire(
                timestampNanos: frame.timestampNanos,
                isPointer: isPointer(frame.event)
            )
            await coordinator.handleIncoming(frame, from: source)
        case let .realtimeInput(source, frame):
            metrics.recordWire(timestampNanos: frame.timestampNanos, isPointer: true)
            await coordinator.handleIncomingRealtime(frame, from: source)
        case .discovered, .lost, .workspaceUpgradeRequired, .health, .failure:
            break
        }
    }

    private func handleControl(_ message: ControlMessage, from source: DeviceID) async {
        switch message {
        case let .controllerClaim(epoch):
            await coordinator.observeControllerClaim(epoch)
            emitter.send(.event("controllerClaim", values: [
                "controller": epoch.controllerID.description,
                "generation": String(epoch.generation),
            ]))
        case let .activate(activation):
            let display = try? localDevice().displays.first
            let accepted = await coordinator.receiveActivation(
                activation,
                from: source,
                targetDisplay: display
            )
            emitter.send(.event("activationReceived", values: [
                "accepted": String(accepted),
                "source": source.description,
                "controller": activation.epoch.controllerID.description,
                "targetDisplay": activation.targetDisplayID.description,
                "localDisplay": display?.id.description ?? "nil",
                "localDevice": localID.description,
            ]))
            try? await transport.send(
                ControlEnvelope(message: .activationResult(
                    sessionID: activation.sessionID,
                    accepted: accepted
                )),
                to: source
            )
        case let .activationResult(sessionID, accepted):
            _ = await coordinator.receiveActivationResult(
                sessionID: sessionID,
                from: source,
                accepted: accepted
            )
        case .deactivate, .releaseAll:
            await coordinator.deactivateCurrentSession()
        case let .heartbeat(sessionID, timestampNanos):
            if await coordinator.receiveHeartbeat(sessionID: sessionID, from: source) {
                if let progress = await coordinator.realtimePointerProgress(
                    sessionID: sessionID,
                    from: source
                ) {
                    try? await transport.send(
                        ControlEnvelope(message: .realtimePointerProgress(progress)),
                        to: source
                    )
                }
                try? await transport.send(
                    ControlEnvelope(message: .heartbeat(
                        sessionID: sessionID,
                        timestampNanos: timestampNanos
                    )),
                    to: source
                )
            } else {
                _ = await coordinator.receiveHeartbeatEcho(
                    sessionID: sessionID,
                    from: source,
                    sentAtNanos: timestampNanos
                )
            }
        case let .realtimePointerProgress(progress):
            _ = await coordinator.receiveRealtimePointerProgress(progress, from: source)
        case .hello, .workspace, .boundaryCrossed, .rotateWorkspaceKey:
            break
        }
    }

    private func stop() async {
        guard !stopping else { return }
        stopping = true
        clipboardChurnTask?.cancel()
        peerEventsTask?.cancel()
        await clipboardCoordinator.stop()
        await fileCoordinator.stop()
        await coordinator.stop()
        await transport.stop()
        await pasteboard.release()
    }

    private func waitForListeners() async throws {
        for _ in 0..<250 {
            if transport.activeControlPort != nil,
               await clipboardCoordinator.isSharingEnabled() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SimulationFailure.timeout("Node listeners did not become ready")
    }

    private func makeWorkspace() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: WorkspaceID(rawValue: configuration.workspaceID),
            name: "Simulation",
            localDeviceID: localID,
            devices: [try! localDevice(), try! peerDevice()]
        )
    }

    private func localDevice() throws -> DeviceDescriptor {
        try device(
            id: localID,
            displayID: DisplayID(rawValue: configuration.displayID),
            name: configuration.name
        )
    }

    private func peerDevice() throws -> DeviceDescriptor {
        try device(
            id: peerID,
            displayID: DisplayID(rawValue: configuration.peerDisplayID),
            name: configuration.peerName
        )
    }

    private func device(id: DeviceID, displayID: DisplayID, name: String) throws -> DeviceDescriptor {
        DeviceDescriptor(
            id: id,
            name: name,
            displays: [DisplayDescriptor(
                id: displayID,
                deviceID: id,
                name: "\(name) Display",
                frame: .init(x: 0, y: 0, width: 1_920, height: 1_080),
                scaleFactor: 2,
                isMain: true
            )],
            peerAddresses: [try PeerAddress("127.0.0.1")],
            capabilities: [
                .publicTrackpadGestures,
                .udpPointerV2,
                .activationAcknowledgementV1,
                .realtimePointerProgressV1,
                .fileTransferV1,
                .clipboardTextV1,
                .clipboardURLV1,
            ],
            platform: .macOS
        )
    }

    private func isPointer(_ event: InputEvent) -> Bool {
        if case .pointerMove = event { return true }
        return false
    }

    private func writeClipboard(_ value: String) async {
        await pasteboard.writeClipboard(value)
    }

    private func readClipboard() async -> String? {
        await pasteboard.readClipboard()
    }

    private func startClipboardChurn() {
        clipboardChurnTask?.cancel()
        clipboardChurnTask = Task { [weak self] in
            var sequence = 0
            while !Task.isCancelled, let self {
                await self.writeClipboard("churn-\(sequence)-\(String(repeating: "x", count: 1_024))")
                sequence += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func generatedFiles(byteCount: Int, fileCount: Int) throws -> [URL] {
        let directory = URL(fileURLWithPath: configuration.stateDirectory, isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<max(fileCount, 1)).map { index in
            let url = directory.appendingPathComponent("simulation-\(index).bin")
            try SimulationFiles.writeDeterministicFile(at: url, byteCount: max(byteCount, 1))
            return url
        }
    }

    private func writeFileSelection(_ urls: [URL]) async {
        await pasteboard.writeFiles(urls)
    }

    private func readFileSelection() async -> [URL] {
        await pasteboard.readFiles()
    }
}

func runSimulationNode(configurationURL: URL) async throws {
    let data = try Data(contentsOf: configurationURL)
    let configuration = try SimulationJSON.decoder.decode(
        SimulationNodeConfiguration.self,
        from: data
    )
    let emitter = SimulationLineEmitter()
    let runtime = try await SimulationNodeRuntime(configuration: configuration, emitter: emitter)
    try await runtime.start()

    while let line = readLine() {
        guard let data = line.data(using: .utf8) else { continue }
        do {
            let command = try SimulationJSON.decoder.decode(SimulationCommand.self, from: data)
            if await !runtime.handle(command) { break }
        } catch {
            emitter.send(.event("invalidCommand", values: ["error": error.localizedDescription]))
        }
    }
}
