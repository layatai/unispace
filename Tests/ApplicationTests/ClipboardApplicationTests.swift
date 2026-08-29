import Foundation
import XCTest
@testable import UniSpaceApplication
import UniSpaceDomain

final class ClipboardApplicationTests: XCTestCase {
    @MainActor
    func testFrameCodecRoundTripsAndRejectsMalformedFrames() throws {
        let fixture = ClipboardTestFixture()
        let envelope = fixture.envelope(text: "hello")
        let encoded = try ClipboardFrameCodec.encode(envelope)

        XCTAssertEqual(try ClipboardFrameCodec.decode(encoded), envelope)
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(Data()))
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(
            Data(repeating: 0, count: ClipboardFrameCodec.maximumEncodedSize + 1)
        ))

        var unsupportedVersion = encoded
        unsupportedVersion[0] = 0
        unsupportedVersion[1] = 2
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(unsupportedVersion))

        var unknownKind = encoded
        unknownKind[2] = 99
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(unknownKind))

        var wrongLength = encoded
        wrongLength[35...38] = Data([0, 0, 0, 0])
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(wrongLength))

        var malformedPayload = encoded
        malformedPayload.replaceSubrange(
            ClipboardFrameCodec.headerSize..<malformedPayload.count,
            with: Data(repeating: 0, count: malformedPayload.count - ClipboardFrameCodec.headerSize)
        )
        XCTAssertThrowsError(try ClipboardFrameCodec.decode(malformedPayload))

        let future = ClipboardEnvelope(
            version: 2,
            workspaceID: envelope.workspaceID,
            senderDeviceID: envelope.senderDeviceID,
            payload: envelope.payload
        )
        XCTAssertThrowsError(try ClipboardFrameCodec.encode(future))
    }

    func testSyncEngineOrdersDeduplicatesPrunesAndResets() throws {
        let local = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let remote = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let limits = ClipboardLimits(
            maximumRepresentations: 2,
            maximumRepresentationBytes: 100,
            maximumPayloadBytes: 200,
            recentPayloadCapacity: 1,
            recentPayloadLifetime: 1
        )
        var engine = ClipboardSyncEngine(localDeviceID: local, limits: limits)
        let firstDate = Date(timeIntervalSince1970: 10)
        let representations = [ClipboardRepresentation(kind: .plainText, value: "first")]

        let first = try XCTUnwrap(engine.makeLocalPayload(
            representations: representations,
            now: firstDate
        ))
        let repeated = try XCTUnwrap(engine.makeLocalPayload(
            representations: representations,
            now: firstDate
        ))
        XCTAssertGreaterThan(repeated.revision, first.revision)
        XCTAssertEqual(repeated.contentHash, first.contentHash)
        XCTAssertEqual(engine.recentPayloadCount, 1)
        XCTAssertEqual(engine.currentOrderingKey?.originDeviceID, local)

        let remotePayload = makePayload(
            origin: remote,
            revision: first.revision + 1,
            text: "remote",
            date: firstDate
        )
        XCTAssertTrue(try engine.acceptRemote(remotePayload, from: remote, now: firstDate))
        XCTAssertFalse(try engine.acceptRemote(remotePayload, from: remote, now: firstDate))
        let repeatedRemotePayload = makePayload(
            origin: remote,
            revision: remotePayload.revision + 1,
            text: "remote",
            date: firstDate
        )
        XCTAssertTrue(try engine.acceptRemote(
            repeatedRemotePayload,
            from: remote,
            now: firstDate
        ))
        XCTAssertThrowsError(try engine.acceptRemote(remotePayload, from: local, now: firstDate))

        let badDigest = ClipboardPayload(
            originDeviceID: remote,
            revision: remotePayload.revision + 1,
            timestamp: firstDate,
            contentHash: Data(repeating: 0, count: 32),
            representations: remotePayload.representations
        )
        XCTAssertThrowsError(try engine.acceptRemote(badDigest, from: remote, now: firstDate))

        engine.prune(now: firstDate.addingTimeInterval(2))
        XCTAssertEqual(engine.recentPayloadCount, 0)
        engine.reset(localDeviceID: remote)
        XCTAssertNil(engine.currentOrderingKey)
        XCTAssertNotNil(try engine.makeLocalPayload(
            representations: [ClipboardRepresentation(kind: .url, value: "https://example.com")],
            now: firstDate
        ))

        XCTAssertTrue(ClipboardOrderingKey(revision: 1, originDeviceID: local)
            < ClipboardOrderingKey(revision: 2, originDeviceID: local))
        XCTAssertTrue(ClipboardOrderingKey(revision: 2, originDeviceID: local)
            < ClipboardOrderingKey(revision: 2, originDeviceID: remote))
    }

    @MainActor
    func testCoordinatorRetainsClipboardUntilRemoteFocusIsActive() async throws {
        let fixture = ClipboardTestFixture()
        try await fixture.start()
        await fixture.coordinator.setSharingEnabled(true)
        fixture.transport.emit(.connected(fixture.remote.id))
        let connected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(connected)

        fixture.clipboard.emit(ClipboardObservation(
            changeCount: 1,
            representations: [ClipboardRepresentation(kind: .plainText, value: "copied locally")]
        ))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.transport.sentEnvelopes.isEmpty)

        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)

        let sent = await eventually {
            fixture.transport.sentEnvelopes.first?.payload.representations == [
                ClipboardRepresentation(kind: .plainText, value: "copied locally")
            ]
        }
        XCTAssertTrue(sent)

        fixture.clipboard.emit(ClipboardObservation(
            changeCount: 2,
            representations: [ClipboardRepresentation(kind: .plainText, value: "copied locally")]
        ))
        let resent = await eventually {
            fixture.transport.sentEnvelopes.count == 2
        }
        XCTAssertTrue(resent)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorRetriesIdenticalClipboardAfterSendFailure() async throws {
        let fixture = ClipboardTestFixture()
        fixture.transport.failuresRemaining = 1
        try await fixture.start()
        await fixture.coordinator.setSharingEnabled(true)
        fixture.transport.emit(.connected(fixture.remote.id))
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        let connected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(connected)

        let observation = ClipboardObservation(
            changeCount: 1,
            representations: [ClipboardRepresentation(kind: .plainText, value: "retry me")]
        )
        fixture.clipboard.emit(observation)
        let firstAttempted = await eventually { fixture.transport.sendAttemptCount == 1 }
        XCTAssertTrue(firstAttempted)

        fixture.clipboard.emit(ClipboardObservation(
            changeCount: 2,
            representations: observation.representations
        ))
        let retried = await eventually { fixture.transport.sendAttemptCount == 2 }
        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.transport.sentEnvelopes.count, 1)
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorAppliesOnlyValidActivePeerUpdatesAndStopsCleanly() async throws {
        let fixture = ClipboardTestFixture()
        try await fixture.start()
        await fixture.coordinator.setSharingEnabled(true)
        await fixture.coordinator.setAutomaticDestination(fixture.local.id)
        fixture.transport.emit(.connected(fixture.remote.id))
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        let connected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(connected)

        let envelope = fixture.envelope(text: "remote value")
        fixture.transport.emit(.update(fixture.remote.id, envelope))
        let applied = await eventually { fixture.clipboard.appliedPayloads.count == 1 }
        XCTAssertTrue(applied)

        fixture.transport.emit(.update(fixture.remote.id, envelope))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.clipboard.appliedPayloads.count, 1)

        let wrongWorkspace = ClipboardEnvelope(
            workspaceID: WorkspaceID(),
            senderDeviceID: envelope.senderDeviceID,
            payload: envelope.payload
        )
        fixture.transport.emit(.update(fixture.remote.id, wrongWorkspace))
        fixture.transport.emit(.failure(fixture.remote.id))
        fixture.transport.emit(.update(fixture.remote.id, fixture.envelope(text: "ignored", revision: 2)))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.clipboard.appliedPayloads.count, 1)

        await fixture.coordinator.setSharingEnabled(false)
        let sharingEnabled = await fixture.coordinator.isSharingEnabled()
        XCTAssertFalse(sharingEnabled)
        await fixture.coordinator.stop()
        XCTAssertTrue(fixture.transport.stopCount > 0)
        XCTAssertTrue(fixture.clipboard.stopCount > 0)
    }

    @MainActor
    func testCoordinatorRejectsInvalidStartupAndTransportFailure() async {
        let fixture = ClipboardTestFixture()
        await XCTAssertThrowsErrorAsync {
            try await fixture.coordinator.start(
                localDevice: fixture.local,
                workspace: fixture.workspace,
                key: Data()
            )
        }

        fixture.transport.startError = ClipboardTestError.failed
        await XCTAssertThrowsErrorAsync {
            try await fixture.coordinator.start(
                localDevice: fixture.local,
                workspace: fixture.workspace,
                key: Data(repeating: 1, count: 32)
            )
        }
        await fixture.coordinator.stop()
    }

    @MainActor
    func testCoordinatorKeepsSingleTransportSubscriptionAcrossRestart() async throws {
        let fixture = ClipboardTestFixture()
        try await fixture.start()
        await fixture.coordinator.setSharingEnabled(true)
        await fixture.coordinator.stop()
        try await fixture.start()

        XCTAssertEqual(fixture.transport.eventSubscriptionCount, 1)
        fixture.transport.emit(.connected(fixture.remote.id))
        await fixture.coordinator.setAutomaticDestination(fixture.remote.id)
        let connected = await eventually {
            await fixture.coordinator.connectedDeviceIDs().contains(fixture.remote.id)
        }
        XCTAssertTrue(connected)
        fixture.clipboard.emit(ClipboardObservation(
            changeCount: 1,
            representations: [ClipboardRepresentation(kind: .plainText, value: "after restart")]
        ))
        let sent = await eventually {
            fixture.transport.sentEnvelopes.first?.payload.plainText == "after restart"
        }
        XCTAssertTrue(sent)
        await fixture.coordinator.stop()
    }

    private func makePayload(
        origin: DeviceID,
        revision: UInt64,
        text: String,
        date: Date
    ) -> ClipboardPayload {
        let representations = [ClipboardRepresentation(kind: .plainText, value: text)]
        return ClipboardPayload(
            originDeviceID: origin,
            revision: revision,
            timestamp: date,
            contentHash: ClipboardSyncEngine.contentHash(for: representations),
            representations: representations
        )
    }
}

private enum ClipboardTestError: Error { case failed }

@MainActor
private final class ClipboardTestFixture {
    let local = DeviceDescriptor(id: DeviceID(), name: "Local")
    let remote = DeviceDescriptor(id: DeviceID(), name: "Remote")
    let workspace: WorkspaceSnapshot
    let transport = ClipboardTransportSpy()
    let clipboard = ClipboardServiceSpy()
    let coordinator: ClipboardCoordinator

    init() {
        workspace = WorkspaceSnapshot(
            id: WorkspaceID(),
            name: "Clipboard",
            localDeviceID: local.id,
            devices: [local, remote]
        )
        coordinator = ClipboardCoordinator(transport: transport, clipboard: clipboard)
    }

    func start() async throws {
        try await coordinator.start(
            localDevice: local,
            workspace: workspace,
            key: Data(repeating: 1, count: 32)
        )
    }

    func envelope(text: String, revision: UInt64 = 1) -> ClipboardEnvelope {
        let representations = [ClipboardRepresentation(kind: .plainText, value: text)]
        let payload = ClipboardPayload(
            originDeviceID: remote.id,
            revision: revision,
            timestamp: Date(timeIntervalSince1970: 10),
            contentHash: ClipboardSyncEngine.contentHash(for: representations),
            representations: representations
        )
        return ClipboardEnvelope(
            workspaceID: workspace.id,
            senderDeviceID: remote.id,
            payload: payload
        )
    }
}

private final class ClipboardTransportSpy: ClipboardTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<ClipboardTransportEvent>
    private let continuation: AsyncStream<ClipboardTransportEvent>.Continuation
    private var attempts = 0
    private var sent: [ClipboardEnvelope] = []
    private var stops = 0
    private var eventSubscriptions = 0
    var failuresRemaining = 0
    var startError: Error?

    init() {
        var captured: AsyncStream<ClipboardTransportEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    var sendAttemptCount: Int { lock.withLock { attempts } }
    var sentEnvelopes: [ClipboardEnvelope] { lock.withLock { sent } }
    var stopCount: Int { lock.withLock { stops } }
    var eventSubscriptionCount: Int { lock.withLock { eventSubscriptions } }

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws {
        if let startError { throw startError }
    }

    func stop() async { lock.withLock { stops += 1 } }
    func events() -> AsyncStream<ClipboardTransportEvent> {
        lock.withLock { eventSubscriptions += 1 }
        return stream
    }

    func send(_ envelope: ClipboardEnvelope, to deviceID: DeviceID) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            attempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                return true
            }
            sent.append(envelope)
            return false
        }
        if shouldFail { throw ClipboardTestError.failed }
    }

    func emit(_ event: ClipboardTransportEvent) { continuation.yield(event) }
}

@MainActor
private final class ClipboardServiceSpy: ClipboardService {
    private let stream: AsyncStream<ClipboardObservation>
    private let continuation: AsyncStream<ClipboardObservation>.Continuation
    private(set) var appliedPayloads: [ClipboardPayload] = []
    private(set) var stopCount = 0

    init() {
        var captured: AsyncStream<ClipboardObservation>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func events() -> AsyncStream<ClipboardObservation> { stream }
    func stop() { stopCount += 1 }
    func apply(_ payload: ClipboardPayload) { appliedPayloads.append(payload) }
    func emit(_ observation: ClipboardObservation) { continuation.yield(observation) }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch { }
}
