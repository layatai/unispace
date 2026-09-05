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
        // A replay requests an IDR; it cannot replace the displayed access unit.
        try await eventually { !clients[1].isSending }
        XCTAssertTrue(clients[1].send(try SeamlessWindowCodec.encode(frame)))
        try await eventually { messages.contains(.keyframe(lease.epoch)) }
        XCTAssertEqual(service.presentedFrameCount, 1)
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

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else {
            XCTFail("Timed out waiting for the window session")
            throw SeamlessWindowError.unavailable
        }
    }
}

@MainActor
private final class ForegroundWindowFixture: NSWindow {
    var foreground = false
    override var isKeyWindow: Bool { foreground }
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
