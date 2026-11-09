import CryptoKit
import Foundation
import Testing
@testable import UniSpaceApplication
import UniSpaceDomain

struct LossyTransportHarnessTests {
    // MARK: Determinism (pure pipe, no time or network involvement)

    @Test func identicalSeedsReplayIdenticalDropReorderSequences() async throws {
        func channel(seed: UInt64) -> (dispositions: [LossyDisposition], emissions: [Int]) {
            let profile = LossyProfile(seed: seed, lossProbability: 0.3, reorderDelayProbability: 0.35,
                                       maxReorderSlots: 4, duplicateProbability: 0.1)
            let pipe = LossyPipe<Int>(profile: profile)
            var emissions: [Int] = []
            for frame in 0..<48 { emissions.append(contentsOf: pipe.feed(frame).emissions) }
            emissions.append(contentsOf: pipe.flush())
            return (pipe.dispositions, emissions)
        }
        let seed = 0x2545_F491_4F6C_DD1D
        let first = channel(seed: seed)
        let second = channel(seed: seed)
        #expect(first.dispositions == second.dispositions)
        #expect(first.emissions == second.emissions)
        // Survivors are permuted, never invented or corrupted: emitted multiset
        // equals the feed minus drops plus duplicates.
        var survivors = [Int: Int](uniqueKeysWithValues: (0..<48).map { ($0, 1) })
        var emitted = [Int: Int]()
        for frame in first.emissions { emitted[frame, default: 0] += 1 }
        for (index, disposition) in first.dispositions.enumerated() {
            if disposition == .drop { survivors.removeValue(forKey: index) }
            if disposition == .deliverAndDuplicate || disposition == .delayAndDuplicate { survivors[index, default: 0] += 1 }
        }
        #expect(emitted == survivors, "Loss and duplicates only shape the delivery set, they never rewrite it")
        // A different seed produces a different sequence for the same series.
        let other = channel(seed: seed &+ 1)
        #expect(first.dispositions != other.dispositions)
        #expect(first.emissions != other.emissions)
        #expect(first.dispositions.contains(.drop), "Feeds at loss 0.3 exercise the drop path")
        #expect(first.dispositions.contains { $0 == .delay || $0 == .delayAndDuplicate },
                "Feeds at reorder probability 0.35 exercise the rebuffer path")
    }

    // MARK: Clipboard stream under loss (paired coordinators, correlated requests)

    @Test(arguments: [0.0, 0.05, 0.15, 0.30],
          [0x9E37_79B9_7F4A_7C15, 0xBF58_476D_1CE4_E5B9, 0x94D0_49BB_1331_11EB, 0x2545_F491_4F6C_DD1D, 0xA076_1D64_78BD_642F])
    func downloadShapeSurvivesLossWithCorrelatedRequests(lossProbability: Double, seed: UInt64) async throws {
        let fixture = LossyStreamPairFixture(lossProbability: lossProbability, seed: seed)
        await fixture.start()
        try await fixture.sender.copied([URL(fileURLWithPath: "/fixture/a")])
        var selection = await fixture.receiver.selection(from: fixture.local.id)
        for _ in 0..<400 where selection == nil {
            try await Task.sleep(for: .milliseconds(5))
            selection = await fixture.receiver.selection(from: fixture.local.id)
        }
        let announced = try #require(selection, "The exempted announce frame must surface the remote selection")
        // open/read/read/finish with test-level retry: every issued requestID
        // ends answered (the coordinator validates the requestID echo and rejects
        // mismatched responses as invalidRequest) or with a typed
        // ClipboardStreamFailure - unavailable/expired/cancelled remain
        // retryable, anything else fails the run. The production 30 s request
        // expiry bounds every await, so a broken harness cannot hang the suite.
        let content = Data("abcdef".utf8)
        var received = Data()
        let lease = try await retrying("open") {
            try await fixture.receiver.open(selection: announced, file: announced.files[0], peer: fixture.local.id)
        }
        received += try await retrying("read:0") {
            try await fixture.receiver.read(lease: lease, offset: 0, length: 2, peer: fixture.local.id)
        }
        received += try await retrying("read:2") {
            try await fixture.receiver.read(lease: lease, offset: 2, length: 4, peer: fixture.local.id)
        }
        try await retrying("finish") {
            try await fixture.receiver.finish(lease: lease, digest: Data(SHA256.hash(data: content)), peer: fixture.local.id)
        }
        #expect(received == content, "Retried offset reads must reassemble the exact transfer content")
        #expect(await fixture.source.reader.closed)
        await fixture.stop()
    }

    private func retrying<T>(_ step: String, maxAttempts: Int = 24, _ operation: () async throws -> T) async throws -> T {
        for _ in 0..<maxAttempts {
            do { return try await operation() }
            catch let failure as ClipboardStreamFailure
            where failure == .unavailable || failure == .expired || failure == .cancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("Step \(step) exceeded \(maxAttempts) bounded retry attempts under loss")
        throw ClipboardStreamFailure.unavailable
    }

    // MARK: Pointer stability under loss and reordering (running totals)

    @Test func pointerConvergesToLastDeliveredCumulativeWithoutDrift() async throws {
        let workspace = WorkspaceID()
        let peer = DeviceID()
        let epoch = ControllerEpoch(generation: 1, controllerID: peer)
        let session = SessionID()
        let frameCount = 24
        func scripted(_ index: Int) -> RealtimePointerFrame {
            .init(workspaceID: workspace, sessionID: session, controllerID: peer, epoch: epoch,
                  generation: 1, sequence: UInt64(index), deltaX: 1, deltaY: -1,
                  cumulativeDeltaX: Double(index + 1), cumulativeDeltaY: -Double(index + 1),
                  absoluteX: 0, absoluteY: 0, timestampNanos: 0)
        }
        for loss in [0.0, 0.05, 0.15, 0.30] {
            let injector = PointingInjectorSpy()
            let receiver = RealtimeInputReceiver(workspaceID: workspace, injector: injector)
            receiver.begin(epoch: epoch, source: peer, sessionID: session)
            let profile = LossyProfile(seed: 0x2545_F491_4F6C_DD1D, lossProbability: loss, reorderDelayProbability: 0.35,
                                       maxReorderSlots: 4, duplicateProbability: 0.1)
            let pipe = LossyPipe<RealtimePointerFrame>(profile: profile)
            for index in 0..<frameCount { _ = pipe.feed(scripted(index)).emissions }
            for frame in pipe.flush() { _ = receiver.receive(frame, from: peer) }
            let dispositions = pipe.dispositions
            // Lost moves need no retransmission: every delivered frame carries
            // a running total, so integrating the injected deltas lands exactly
            // on the cumulative value of the last delivered frame. Reordered
            // and duplicated frames are fenced by the sequence guard and never
            // apply motion twice, so there is no drift.
            for index in stride(from: frameCount - 1, through: 0, by: -1) where dispositions[index] != .drop {
                let survivor = scripted(index)
                #expect(injector.x == survivor.cumulativeDeltaX, "Integrated X must equal the running total of the last delivered frame")
                #expect(injector.y == survivor.cumulativeDeltaY, "Integrated Y must equal the running total of the last delivered frame")
                if loss == 0 {
                    #expect(injector.x == Double(frameCount), "Without loss every move arrives, so the pointer lands on the scripted end")
                    #expect(injector.y == -Double(frameCount))
                }
                break
            }
        }
    }
}

private final class PointingInjectorSpy: InputInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var integratedX: Double = 0
    private var integratedY: Double = 0
    var x: Double { lock.withLock { integratedX } }
    var y: Double { lock.withLock { integratedY } }
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double) {}
    func inject(_ event: InputEvent) {
        guard case let .pointerMove(deltaX, deltaY, _, _) = event else { return }
        lock.withLock {
            integratedX += deltaX
            integratedY += deltaY
        }
    }
    func releaseAll() {}
}

final class LossyStreamPairFixture: Sendable {
    let local: DeviceDescriptor
    let remote: DeviceDescriptor
    let workspace: WorkspaceSnapshot
    // Mirrors StreamPairFixture, wrapping both directions in LossyTransport.
    let source = StreamSourceSpy()
    let receiverAdapter = StreamAdapterSpy()
    let sender: ClipboardStreamCoordinator
    let receiver: ClipboardStreamCoordinator

    init(lossProbability: Double, seed: UInt64) {
        local = DeviceDescriptor(id: DeviceID(), name: "Lossy Source",
                                 capabilities: [.fileTransferV1, .fileClipboardStreamV2])
        remote = DeviceDescriptor(id: DeviceID(), name: "Lossy Destination",
                                  capabilities: [.fileTransferV1, .fileClipboardStreamV2])
        workspace = WorkspaceSnapshot(id: WorkspaceID(), name: "Lossy Clipboard QA", localDeviceID: local.id,
                                      devices: [local, remote])
        let senderLoopback = StreamLoopbackTransport()   // delivers sender traffic to the receiver
        let receiverLoopback = StreamLoopbackTransport() // delivers receiver traffic to the sender
        // Dropped requests must notify their requester across the pair, so the
        // receiver direction routes synthesized notices through the sender's
        // loopback, which is connected to the receiver coordinator.
        let reachReceiver: @Sendable (FileTransferEnvelope) async -> Void = { notice in
            try? await senderLoopback.send(notice, to: local.id)
        }
        sender = ClipboardStreamCoordinator(transport: LossyTransport(base: senderLoopback,
            profile: LossyProfile(seed: seed, lossProbability: lossProbability, reorderDelayProbability: 0.2,
                                  maxReorderSlots: 4, duplicateProbability: 0.1)),
            source: ClipboardStreamSource(source: source, clock: StreamTestClock()), adapter: StreamAdapterSpy())
        receiver = ClipboardStreamCoordinator(transport: LossyTransport(base: receiverLoopback,
            profile: LossyProfile(seed: seed &+ 1, lossProbability: lossProbability, reorderDelayProbability: 0.2,
                                  maxReorderSlots: 4, duplicateProbability: 0.1),
            failureNoticeRoute: reachReceiver),
            source: ClipboardStreamSource(source: StreamSourceSpy(), clock: StreamTestClock()), adapter: receiverAdapter)
        senderLoopback.connect(to: receiver)
        receiverLoopback.connect(to: sender)
    }

    func start() async {
        await sender.start(localDevice: local, workspace: workspace)
        await receiver.start(localDevice: remote, workspace: workspace)
        await sender.connection(remote.id, active: true)
        await receiver.connection(local.id, active: true)
        await sender.setDestination(remote.id)
    }
    func stop() async { await sender.stop(); await receiver.stop() }
}
