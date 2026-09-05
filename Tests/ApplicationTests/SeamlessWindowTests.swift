import XCTest
import UniSpaceDomain
@testable import UniSpaceApplication

final class SeamlessWindowTests: XCTestCase {
    private func lease() -> WindowPresentationLease {
        WindowPresentationLease(windowID: RemoteWindowID(), source: DeviceID(), destination: DeviceID())
    }
    private func frame(_ lease: WindowPresentationLease, sequence: UInt64 = 0, key: Bool = true) -> SeamlessVideoFrame {
        SeamlessVideoFrame(epoch: lease.epoch, sequence: sequence, width: 640, height: 480,
            keyframe: key, sps: Data([0x67, 1]), pps: Data([0x68, 1]), bytes: Data([0, 0, 0, 2, key ? 0x65 : 0x41, 1]))
    }
    func testOnlyAcceptedDestinationCanControlUnexpiredLease() throws {
        let lease = lease()
        var state = WindowPresentationState()
        try state.offer(lease, now: 10)
        XCTAssertFalse(state.authorizes(epoch: lease.epoch, peer: lease.destination, now: 11))
        XCTAssertThrowsError(try state.offer(self.lease(), now: 11))
        try state.accept(lease, now: 11)
        XCTAssertTrue(state.authorizes(epoch: lease.epoch, peer: lease.destination, now: 12))
        XCTAssertFalse(state.authorizes(epoch: UUID(), peer: lease.destination, now: 12))
        XCTAssertFalse(state.authorizes(epoch: lease.epoch, peer: lease.source, now: 12))
        XCTAssertFalse(state.authorizes(epoch: lease.epoch, peer: lease.destination, now: 21))
        XCTAssertTrue(state.expire(now: 21))
        XCTAssertEqual(state.phase, .idle)
    }
    func testExpiredLeaseCannotBeRevivedByLateHeartbeatOrAcceptance() throws {
        let lease = lease()
        var state = WindowPresentationState()
        try state.offer(lease, now: 0)
        XCTAssertThrowsError(try state.accept(lease, now: 10))
        state.release()
        try state.offer(lease, now: 20)
        try state.accept(lease, now: 21)
        XCTAssertThrowsError(try state.renew(epoch: lease.epoch, now: 31))
        XCTAssertFalse(state.authorizes(epoch: lease.epoch, peer: lease.destination, now: .nan))
        XCTAssertTrue(state.expire(now: .infinity))
    }
    func testHeartbeatRenewsOnlyCurrentEpoch() throws {
        let lease = lease()
        var state = WindowPresentationState()
        try state.offer(lease, now: 0); try state.accept(lease, now: 1)
        XCTAssertThrowsError(try state.renew(epoch: UUID(), now: 2))
        try state.renew(epoch: lease.epoch, now: 9)
        XCTAssertFalse(state.expire(now: 18))
        XCTAssertTrue(state.expire(now: 19))
    }
    func testDecodeRequiresIDRAfterGapAndRejectsReplays() throws {
        let lease = lease()
        var state = WindowPresentationState()
        try state.offer(lease, now: 0); try state.accept(lease, now: 1)
        XCTAssertThrowsError(try state.receive(frame(lease, key: false)))
        try state.receive(frame(lease))
        XCTAssertThrowsError(try state.receive(frame(lease)))
        XCTAssertThrowsError(try state.receive(frame(lease, sequence: 2, key: false)))
        try state.receive(frame(lease, sequence: 3))
        try state.receive(frame(lease, sequence: 4, key: false))
        XCTAssertThrowsError(try state.receive(frame(self.lease(), sequence: 5)))
    }
    func testControlAndVideoRoundTrip() throws {
        let lease = lease()
        let descriptor = SeamlessWindowDescriptor(id: lease.windowID, title: "窗口", application: "Editor", width: 640, height: 480)
        let messages: [SeamlessWindowMessage] = [.offer(lease, descriptor), .accept(lease), .reject(lease.epoch),
            .release(lease.epoch), .heartbeat(lease.epoch), .input(lease.epoch, SeamlessInput(kind: .leftDown, x: 0.5, y: 0.75)),
            .keyframe(lease.epoch), .visibility(lease.epoch, false)]
        for message in messages { XCTAssertEqual(try SeamlessWindowCodec.decode(SeamlessWindowCodec.encode(message)), message) }
        XCTAssertEqual(try SeamlessWindowCodec.decodeFrame(SeamlessWindowCodec.encode(frame(lease))), frame(lease))
    }
    func testInputAndAllocationBoundsRejectUntrustedValues() throws {
        for input in [SeamlessInput(kind: .move, x: .nan), SeamlessInput(kind: .move, y: 1.1),
                      SeamlessInput(kind: .keyDown, keyCode: 128), SeamlessInput(kind: .scroll, deltaY: .infinity),
                      SeamlessInput(kind: .keyDown, modifiers: UInt64.max)] {
            XCTAssertThrowsError(try input.validate())
        }
        XCTAssertThrowsError(try SeamlessWindowDescriptor.validateSize(width: Int.max, height: Int.max))
        XCTAssertThrowsError(try SeamlessWindowDescriptor.validateSize(width: 0, height: 480))
        XCTAssertThrowsError(try SeamlessWindowCodec.decode(Data(count: SeamlessWindowLimits.maximumControlBytes + 1)))
        XCTAssertThrowsError(try SeamlessWindowCodec.decodeFrame(Data(count: SeamlessWindowLimits.maximumFrameBytes + 16_385)))
    }
    func testInvalidAVCCAndFalseKeyframeClaimsAreRejected() {
        for bytes in [Data([0]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 2, 0x41, 0])] {
            let frame = SeamlessVideoFrame(epoch: UUID(), sequence: 0, width: 640, height: 480,
                keyframe: true, sps: Data([0x67]), pps: Data([0x68]), bytes: bytes)
            XCTAssertThrowsError(try frame.validate())
        }
    }
}
