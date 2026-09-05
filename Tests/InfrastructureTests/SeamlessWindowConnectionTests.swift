import Foundation
import AppKit
import CoreVideo
import CoreMedia
import Network
import XCTest
import UniSpaceApplication
import UniSpaceDomain
@testable import UniSpaceInfrastructure

@MainActor
final class SeamlessWindowConnectionTests: XCTestCase {
    func testEncryptedLoopbackDeliversControlAndEnforcesPayloadBound() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let serverReady = expectation(description: "server authenticated")
        let clientReady = expectation(description: "client authenticated")
        let delivered = expectation(description: "control delivered")
        let message = SeamlessWindowMessage.heartbeat(UUID())
        pair.serverReady = { _ in serverReady.fulfill() }
        pair.serverPacket = { peer, data in
            XCTAssertEqual(peer, pair.clientID)
            XCTAssertEqual(try? SeamlessWindowCodec.decode(data), message)
            delivered.fulfill()
        }
        try await pair.start(clientReady: { _ in clientReady.fulfill() })
        let ready = await XCTWaiter.fulfillment(of: [serverReady, clientReady], timeout: 5)
        XCTAssertEqual(ready, .completed)
        XCTAssertTrue(pair.client?.send(try SeamlessWindowCodec.encode(message)) == true)
        XCTAssertFalse(pair.client?.send(Data(count: SeamlessWindowLimits.maximumControlBytes + 1)) == true)
        let result = await XCTWaiter.fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testWrongWorkspaceKeyClosesWithoutAuthenticating() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let closed = expectation(description: "wrong-key connection rejected")
        pair.serverClosed = { closed.fulfill() }
        pair.serverReady = { _ in XCTFail("Wrong key must not authenticate") }
        try await pair.start(clientKey: Data(repeating: 2, count: 32))
        let result = await XCTWaiter.fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(pair.server?.peer)
    }

    func testVideoHelloCannotAuthenticateOnControlLane() async throws {
        let pair = try ConnectionPair()
        defer { pair.close() }
        let closed = expectation(description: "lane mismatch rejected")
        pair.serverClosed = { closed.fulfill() }
        pair.serverReady = { _ in XCTFail("Lane mismatch must not authenticate") }
        try await pair.start(clientLane: .video)
        let result = await XCTWaiter.fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(pair.server?.peer)
    }

    func testRealH264FrameRendersAndProxyMapsInput() async throws {
        _ = NSApplication.shared
        let epoch = UUID()
        let frame = try await encodedFrame(epoch: epoch)
        try frame.validate()
        XCTAssertTrue(frame.keyframe)
        let descriptor = SeamlessWindowDescriptor(id: RemoteWindowID(), title: "Codec fixture", application: "Fixture", width: 640, height: 480)
        let host = ForegroundWindowFixture(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let proxy = SeamlessWindowProxy(descriptor: descriptor, sourceName: "Test Mac", window: host)
        defer { proxy.close() }
        XCTAssertTrue(try proxy.display(frame))
        try await eventually { proxy.isRendering }
        var inputs: [SeamlessInput] = []
        proxy.onInput = { inputs.append($0) }
        let content = try XCTUnwrap(proxy.nativeWindow.contentView)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: content.bounds.midX, y: content.bounds.midY), modifierFlags: [], timestamp: 1,
            windowNumber: proxy.nativeWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        content.mouseDown(with: click)
        let down = try XCTUnwrap(inputs.last(where: { $0.kind == .leftDown }))
        XCTAssertEqual(down.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(down.y, 0.5, accuracy: 0.01)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 2, windowNumber: proxy.nativeWindow.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        content.keyDown(with: key)
        XCTAssertEqual(inputs.last?.kind, .keyDown)
        XCTAssertEqual(inputs.last?.modifiers, UInt64(NSEvent.ModifierFlags.command.rawValue))
        content.keyUp(with: key)
        XCTAssertEqual(inputs.last?.kind, .keyUp)
        host.foreground = false
        let beforeShortcut = inputs.count
        XCTAssertFalse(content.performKeyEquivalent(with: key))
        XCTAssertEqual(inputs.count, beforeShortcut, "Background windows must not forward shortcuts")
        host.foreground = true
        XCTAssertTrue(content.performKeyEquivalent(with: key))
        XCTAssertEqual(inputs.last?.kind, .keyDown)
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift,
            timestamp: 3, windowNumber: proxy.nativeWindow.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        content.flagsChanged(with: flags)
        XCTAssertEqual(inputs.last?.kind, .flagsChanged)
        XCTAssertEqual(inputs.last?.modifiers, UInt64(NSEvent.ModifierFlags.shift.rawValue))
        // Resizing the proxy changes letterboxing, never the source coordinates.
        proxy.nativeWindow.setContentSize(NSSize(width: 1_280, height: 480))
        for (type, expected) in [(NSEvent.EventType.mouseMoved, SeamlessInput.Kind.move),
            (.leftMouseUp, .leftUp), (.rightMouseDown, .rightDown), (.rightMouseUp, .rightUp),
            (.leftMouseDragged, .leftDrag), (.rightMouseDragged, .rightDrag)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 640, y: 240),
                modifierFlags: [], timestamp: 4, windowNumber: proxy.nativeWindow.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            switch type {
            case .mouseMoved: content.mouseMoved(with: event)
            case .leftMouseUp: content.mouseUp(with: event)
            case .rightMouseDown: content.rightMouseDown(with: event)
            case .rightMouseUp: content.rightMouseUp(with: event)
            case .leftMouseDragged: content.mouseDragged(with: event)
            default: content.rightMouseDragged(with: event)
            }
            XCTAssertEqual(inputs.last?.kind, expected)
            XCTAssertEqual(try XCTUnwrap(inputs.last?.x), 0.5, accuracy: 0.01)
        }
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 240),
            modifierFlags: [], timestamp: 5, windowNumber: proxy.nativeWindow.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        let beforeOutside = inputs.count
        content.mouseDown(with: outside)
        XCTAssertEqual(inputs.count, beforeOutside, "Letterbox clicks must not reach the source")
        content.mouseUp(with: outside)
        XCTAssertEqual(inputs.last?.kind, .leftUp, "Release must work outside the image")
        XCTAssertEqual(inputs.last?.x, 0)
        proxy.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertEqual(inputs.last?.kind, .releaseAll)
        let invalid = SeamlessVideoFrame(epoch: epoch, sequence: 1, width: 800, height: 480,
            keyframe: frame.keyframe, sps: frame.sps, pps: frame.pps, bytes: frame.bytes)
        XCTAssertThrowsError(try proxy.display(invalid))
        var returnedHome = false
        proxy.onClose = { returnedHome = true }
        let emergency = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option, .command], timestamp: 6,
            windowNumber: proxy.nativeWindow.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        content.keyDown(with: emergency)
        XCTAssertTrue(returnedHome)
        var visibility: [Bool] = []
        var requestedKeyframes = 0
        proxy.onVisibility = { visibility.append($0) }
        proxy.onKeyframeNeeded = { requestedKeyframes += 1 }
        host.minimized = true
        proxy.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertEqual(inputs.last?.kind, .releaseAll)
        XCTAssertEqual(visibility.last, false)
        XCTAssertFalse(try proxy.display(frame))
        host.minimized = false
        proxy.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
        XCTAssertEqual(visibility.last, true)
        XCTAssertEqual(requestedKeyframes, 1)
        XCTAssertTrue(try proxy.display(frame))
        returnedHome = false
        proxy.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertTrue(returnedHome)
    }

    func testBonjourServiceCanStartAndStopWithoutCapturingAWindow() async throws {
        let service = SeamlessWindowService(controlPort: .any, videoPort: .any)
        defer { service.stop() }
        let local = DeviceID()
        let workspace = WorkspaceSnapshot(id: WorkspaceID(), name: "Discovery fixture", localDeviceID: local,
            devices: [DeviceDescriptor(id: local, name: "Fixture", platform: .macOS)])
        try service.start(workspace: workspace, local: local, key: Data(repeating: 4, count: 32))
        try await eventually { service.listeningPorts.count == 2 && !service.isPresenting }
        XCTAssertNil(service.incoming)
        service.stop()
        try await eventually { !service.isPresenting }
        XCTAssertTrue(service.listeningPorts.isEmpty)
        XCTAssertEqual(service.status, "Window sharing is off")
    }

    func testReceiverAcceptsEncryptedOfferRendersMediaAndReturnsHomeOnDisconnect() async throws {
        try await receiverSession(unauthorizedInput: false)
    }

    func testReceiverRejectsSourceAttemptToInjectInputIntoViewer() async throws {
        try await receiverSession(unauthorizedInput: true)
    }

    private func receiverSession(unauthorizedInput: Bool) async throws {
        _ = NSApplication.shared
        let service = SeamlessWindowService(controlPort: .any, videoPort: .any, enableBonjour: false)
        defer { service.stop() }
        let local = DeviceID(), source = DeviceID(), workspaceID = WorkspaceID()
        let key = Data(repeating: 3, count: 32)
        let workspace = WorkspaceSnapshot(id: workspaceID, name: "Window fixture", localDeviceID: local,
            devices: [DeviceDescriptor(id: local, name: "Receiver", platform: .macOS),
                      DeviceDescriptor(id: source, name: "Source", platform: .macOS)])
        XCTAssertThrowsError(try service.start(workspace: workspace, local: local, key: Data()))
        try service.start(workspace: workspace, local: local, key: key)
        try await eventually { service.listeningPorts.count == 2 && !service.isPresenting }
        let controlReady = expectation(description: "client control ready")
        let videoReady = expectation(description: "client video ready")
        let delayedVideo = unauthorizedInput
        var clients: [SeamlessWindowConnection] = []
        defer { clients.forEach { $0.close() } }
        var messages: [SeamlessWindowMessage] = []
        for (index, lane) in [SeamlessWindowConnection.Lane.control, .video].enumerated() {
            let network = NWConnection(host: "127.0.0.1", port: service.listeningPorts[index], using: SeamlessWindowConnection.parameters())
            let client = try SeamlessWindowConnection(connection: network, lane: lane, workspace: workspaceID,
                local: source, allowed: [local], expected: local, key: key)
            client.onReady = { _ in (index == 0 ? controlReady : videoReady).fulfill() }
            client.onPacket = { _, data in if let message = try? SeamlessWindowCodec.decode(data) { messages.append(message) } }
            clients.append(client)
            if index == 0 || !delayedVideo { client.start() }
        }
        let connected = await XCTWaiter.fulfillment(of: delayedVideo ? [controlReady] : [controlReady, videoReady], timeout: 5)
        XCTAssertEqual(connected, .completed)
        let lease = WindowPresentationLease(windowID: RemoteWindowID(), source: source, destination: local)
        let descriptor = SeamlessWindowDescriptor(id: lease.windowID, title: "Fixture", application: "Fixture", width: 640, height: 480)
        XCTAssertTrue(clients[0].send(try SeamlessWindowCodec.encode(.offer(lease, descriptor))))
        try await eventually { service.incoming != nil }
        XCTAssertEqual(service.incoming?.0, lease)
        service.accept()
        if delayedVideo {
            XCTAssertNotNil(service.incoming)
            clients[1].start()
            let videoConnected = await XCTWaiter.fulfillment(of: [videoReady], timeout: 5)
            XCTAssertEqual(videoConnected, .completed)
        }
        try await eventually { messages.contains(.accept(lease)) }
        XCTAssertNil(service.incoming)
        XCTAssertTrue(service.isPresenting)
        let frame = try await encodedFrame(epoch: lease.epoch)
        XCTAssertTrue(clients[1].send(try SeamlessWindowCodec.encode(frame)))
        try await eventually { service.presentedFrameCount == 1 }
        let competing = WindowPresentationLease(windowID: RemoteWindowID(), source: source, destination: local)
        let competingDescriptor = SeamlessWindowDescriptor(id: competing.windowID, title: "Second window", application: "Fixture", width: 640, height: 480)
        XCTAssertTrue(clients[0].send(try SeamlessWindowCodec.encode(.offer(competing, competingDescriptor))))
        try await eventually { messages.contains(.reject(competing.epoch)) }
        XCTAssertTrue(service.isPresenting, "A competing offer must not evict the accepted presentation")
        XCTAssertNil(service.incoming)
        // A replay requests an IDR; it cannot replace the displayed access unit.
        try await eventually { !clients[1].isSending }
        XCTAssertTrue(clients[1].send(try SeamlessWindowCodec.encode(frame)))
        try await eventually { messages.contains(.keyframe(lease.epoch)) }
        XCTAssertEqual(service.presentedFrameCount, 1)
        // The real timer must renew the accepted session through its control
        // connection while video remains idle.
        try await eventually { messages.contains(.heartbeat(lease.epoch)) }
        XCTAssertTrue(clients[0].send(try SeamlessWindowCodec.encode(.heartbeat(lease.epoch))))
        if unauthorizedInput {
            // The viewer is never an input-injection target for its source.
            XCTAssertTrue(clients[0].send(try SeamlessWindowCodec.encode(.input(lease.epoch, SeamlessInput(kind: .keyDown)))))
        } else { clients[1].close() }
        try await eventually { !service.isPresenting }
        XCTAssertTrue(service.status.contains(unauthorizedInput ? "stopped" : "Connection ended"))
        service.returnHome(); service.stop()
        XCTAssertTrue(service.listeningPorts.isEmpty)
    }

    private func encodedFrame(epoch: UUID) async throws -> SeamlessVideoFrame {
        let encoded = expectation(description: "VideoToolbox emits H264")
        var result: SeamlessVideoFrame?
        let encoder = try WindowH264Output(epoch: epoch, width: 640, height: 480, onFrame: { frame in
            result = frame; encoded.fulfill(); return true
        }, onFailure: { XCTFail("Encoder failed") })
        defer { encoder.stop() }
        encoder.requestKeyframe()
        encoder.queue.async {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { XCTFail("Pixel buffer allocation failed"); return }
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    memset(base, plane == 0 ? 16 : 128,
                        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            encoder.encode(buffer, at: CMTime(value: 1, timescale: 30))
        }
        let completed = await XCTWaiter.fulfillment(of: [encoded], timeout: 10)
        XCTAssertEqual(completed, .completed)
        return try XCTUnwrap(result)
    }

    func testSourceRoutesOnlyItsLeaseInputAndReleasesOnWindowLoss() async throws {
        let receiver = try WindowReceiverFixture()
        receiver.start()
        defer { receiver.stop() }
        try await eventually { receiver.listeners.allSatisfy { ($0.port?.rawValue ?? 0) != 0 } }
        let capture = WindowCaptureFixture()
        let service = SeamlessWindowService(controlPort: .any, videoPort: .any, enableBonjour: false,
            directControlPort: try XCTUnwrap(receiver.listeners[0].port),
            directVideoPort: try XCTUnwrap(receiver.listeners[1].port), capture: capture)
        defer { service.stop() }
        let source = DeviceDescriptor(id: receiver.sourceID, name: "Source", platform: .macOS)
        let destination = DeviceDescriptor(id: receiver.destinationID, name: "Viewer",
            peerAddresses: [try PeerAddress("127.0.0.1")], platform: .macOS)
        let workspace = WorkspaceSnapshot(id: receiver.workspaceID, name: "Source fixture", localDeviceID: source.id,
            devices: [source, destination])
        try service.start(workspace: workspace, local: source.id, key: receiver.key)
        try await eventually { !service.isPresenting }
        let catalog = try await service.catalog()
        XCTAssertEqual(catalog, [capture.descriptor])
        try service.present(capture.descriptor, on: destination.id)
        try await eventually { capture.frameSink != nil && service.status.hasPrefix("Sharing") }
        let lease = try XCTUnwrap(receiver.lease)
        let frame = try await encodedFrame(epoch: lease.epoch)
        XCTAssertTrue(capture.frameSink?(frame) == true)
        try await eventually { receiver.frames.count == 1 }
        XCTAssertEqual(receiver.frames[0], frame)
        let click = SeamlessInput(kind: .leftDown, x: 0.25, y: 0.75)
        try receiver.send(.input(lease.epoch, click))
        try await eventually { capture.target.events.contains(click) }
        let initialReleases = capture.target.releases
        try receiver.send(.visibility(lease.epoch, false))
        try await eventually { capture.paused }
        XCTAssertGreaterThan(capture.target.releases, initialReleases)
        XCTAssertFalse(capture.frameSink?(frame) == true, "A minimized viewer must not receive video")
        try receiver.send(.visibility(lease.epoch, true))
        try await eventually { !capture.paused && capture.keyframes > 0 }
        let keyframes = capture.keyframes
        try receiver.send(.keyframe(lease.epoch))
        try await eventually { capture.keyframes > keyframes }
        // The source watchdog must restore control when the selected window is
        // gone, regardless of a still-healthy media connection.
        let stopped = capture.stops
        capture.target.isAvailable = false
        try await eventually { !service.isPresenting && capture.stops > stopped }
        XCTAssertGreaterThan(capture.target.releases, initialReleases)
        let oldFailure = capture.failureSink
        oldFailure?()
        XCTAssertFalse(service.isPresenting, "An old capture callback cannot revive its lease")
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else {
            XCTFail("Timed out waiting for the window session", file: file, line: line)
            throw SeamlessWindowError.unavailable
        }
    }
}

@MainActor
private final class ForegroundWindowFixture: NSWindow {
    var foreground = false
    var minimized = false
    override var isKeyWindow: Bool { foreground }
    override var isMiniaturized: Bool { minimized }
}

@MainActor
private final class WindowInputFixture: SeamlessInputTarget {
    var isAvailable = true
    var events: [SeamlessInput] = []
    var releases = 0
    func send(_ input: SeamlessInput) throws { try input.validate(); events.append(input) }
    func releaseAll() { releases += 1 }
}

@MainActor
private final class WindowCaptureFixture: SeamlessCaptureSource {
    let descriptor = SeamlessWindowDescriptor(id: RemoteWindowID(), title: "Fixture", application: "Fixture", width: 640, height: 480)
    let target = WindowInputFixture()
    var frameSink: (@MainActor @Sendable (SeamlessVideoFrame) -> Bool)?
    var failureSink: (@MainActor @Sendable () -> Void)?
    var keyframes = 0
    var paused = false
    var stops = 0
    func catalog() async throws -> [SeamlessWindowDescriptor] { [descriptor] }
    func inputTarget(for id: RemoteWindowID) throws -> any SeamlessInputTarget {
        guard id == descriptor.id else { throw SeamlessWindowError.unavailable }; return target
    }
    func start(id: RemoteWindowID, epoch: UUID,
               onFrame: @escaping @MainActor @Sendable (SeamlessVideoFrame) -> Bool,
               onFailure: @escaping @MainActor @Sendable () -> Void) async throws {
        frameSink = onFrame; failureSink = onFailure
    }
    func requestKeyframe() { keyframes += 1 }
    func setPaused(_ paused: Bool) { self.paused = paused }
    func stop() async { stops += 1 }
}

@MainActor
private final class WindowReceiverFixture {
    let sourceID = DeviceID(), destinationID = DeviceID(), workspaceID = WorkspaceID()
    let key = Data(repeating: 5, count: 32)
    let listeners: [NWListener]
    var connections: [SeamlessWindowConnection] = []
    var control: SeamlessWindowConnection?
    var lease: WindowPresentationLease?
    var frames: [SeamlessVideoFrame] = []
    init() throws {
        listeners = try [NWListener(using: SeamlessWindowConnection.parameters(), on: .any),
                         NWListener(using: SeamlessWindowConnection.parameters(), on: .any)]
    }
    func start() {
        for (index, listener) in listeners.enumerated() {
            listener.newConnectionHandler = { [weak self] network in
                Task { @MainActor [weak self] in
                    guard let self else { network.cancel(); return }
                    do {
                        let connection = try SeamlessWindowConnection(connection: network, lane: index == 0 ? .control : .video,
                            workspace: self.workspaceID, local: self.destinationID, allowed: [self.sourceID],
                            expected: self.sourceID, key: self.key)
                        self.connections.append(connection)
                        if index == 0 { self.control = connection }
                        connection.onPacket = { [weak self, weak connection] _, data in
                            guard let self else { return }
                            do {
                                if index == 1 { self.frames.append(try SeamlessWindowCodec.decodeFrame(data)); return }
                                if case let .offer(lease, _) = try SeamlessWindowCodec.decode(data) {
                                    self.lease = lease
                                    connection?.send(try SeamlessWindowCodec.encode(.accept(lease)))
                                }
                            } catch { XCTFail("Receiver fixture rejected a valid packet: \(error)") }
                        }
                        connection.start()
                    } catch { XCTFail("Receiver fixture connection failed: \(error)"); network.cancel() }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }
    func send(_ message: SeamlessWindowMessage) throws {
        XCTAssertTrue(control?.send(try SeamlessWindowCodec.encode(message)) == true)
    }
    func stop() { listeners.forEach { $0.cancel() }; connections.forEach { $0.close() } }
}

@MainActor
private final class ConnectionPair {
    let serverID = DeviceID()
    let clientID = DeviceID()
    let workspace = WorkspaceID()
    let key = Data(repeating: 1, count: 32)
    let listener: NWListener
    var client: SeamlessWindowConnection?
    var server: SeamlessWindowConnection?
    var serverReady: ((DeviceID) -> Void)?
    var serverPacket: ((DeviceID, Data) -> Void)?
    var serverClosed: (() -> Void)?

    init() throws { listener = try NWListener(using: SeamlessWindowConnection.parameters(), on: .any) }

    func start(clientKey: Data? = nil, clientLane: SeamlessWindowConnection.Lane = .control,
               clientReady: ((DeviceID) -> Void)? = nil) async throws {
        let listening = XCTestExpectation(description: "listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { [weak self] network in
            Task { @MainActor [weak self] in
                guard let self else { network.cancel(); return }
                do {
                    let server = try SeamlessWindowConnection(connection: network, lane: .control, workspace: self.workspace,
                        local: self.serverID, allowed: [self.clientID], expected: self.clientID, key: self.key)
                    self.server = server
                    server.onReady = self.serverReady; server.onPacket = self.serverPacket; server.onClosed = self.serverClosed
                    server.start()
                } catch { XCTFail("Could not create server: \(error)"); network.cancel() }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        let result = await XCTWaiter.fulfillment(of: [listening], timeout: 3)
        XCTAssertEqual(result, .completed)
        let port = try XCTUnwrap(listener.port)
        let network = NWConnection(host: "127.0.0.1", port: port, using: SeamlessWindowConnection.parameters())
        let client = try SeamlessWindowConnection(connection: network, lane: clientLane, workspace: workspace,
            local: clientID, allowed: [serverID], expected: serverID, key: clientKey ?? key)
        self.client = client; client.onReady = clientReady
        client.start()
    }

    func close() {
        listener.cancel()
        client?.onClosed = nil; server?.onClosed = nil
        client?.close(); server?.close()
        client = nil; server = nil
    }
}
