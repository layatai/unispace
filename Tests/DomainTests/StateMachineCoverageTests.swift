import XCTest
@testable import UniSpaceDomain

final class StateMachineCoverageTests: XCTestCase {
    func testControllerStateMachineInitializesAfterExistingEpochAndRejectsOlderClaims() {
        let current = ControllerEpoch(generation: 9, controllerID: DeviceID())
        var machine = ControllerStateMachine(currentEpoch: current, nextGeneration: 1)

        XCTAssertFalse(machine.observe(current))
        XCTAssertFalse(machine.observe(.init(generation: 8, controllerID: DeviceID())))
        XCTAssertEqual(machine.claim(for: DeviceID()).generation, 10)
    }

    func testControllerStateMachineAcceptsOnlyCurrentControllerAndEpoch() {
        let controller = DeviceID()
        let other = DeviceID()
        var machine = ControllerStateMachine()
        let epoch = machine.claim(for: controller)

        XCTAssertTrue(machine.accepts(frame(controller: controller, epoch: epoch)))
        XCTAssertFalse(machine.accepts(frame(controller: other, epoch: epoch)))
        XCTAssertFalse(machine.accepts(frame(
            controller: controller,
            epoch: .init(generation: epoch.generation + 1, controllerID: controller)
        )))
    }

    func testRemoteInputStateTracksAllKeysAndButtonsAndIgnoresStatelessEvents() {
        var state = RemoteInputState()
        state.apply(.pointerMove(deltaX: 1, deltaY: 2, absoluteX: 3, absoluteY: 4))
        state.apply(.scroll(deltaX: 1, deltaY: 2, isContinuous: true))
        state.apply(.gesture(serializedEvent: Data([1])))
        state.apply(.flags(rawValue: 3))
        state.apply(.key(code: 9, isDown: true, isRepeat: false))
        state.apply(.key(code: 2, isDown: true, isRepeat: true))
        state.apply(.key(code: 7, isDown: true, isRepeat: false))
        state.apply(.key(code: 9, isDown: false, isRepeat: false))
        state.apply(.mouseButton(button: .other, isDown: true, clickCount: 1))
        state.apply(.mouseButton(button: .left, isDown: true, clickCount: 1))
        state.apply(.mouseButton(button: .right, isDown: true, clickCount: 1))
        state.apply(.mouseButton(button: .other, isDown: false, clickCount: 1))

        XCTAssertEqual(state.releaseEvents(), [
            .key(code: 2, isDown: false, isRepeat: false),
            .key(code: 7, isDown: false, isRepeat: false),
            .mouseButton(button: .left, isDown: false, clickCount: 1),
            .mouseButton(button: .right, isDown: false, clickCount: 1)
        ])
        XCTAssertTrue(state.releaseEvents().isEmpty)
    }

    func testControllerEpochOrdersByGenerationThenDeviceIdentifier() {
        let low = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        XCTAssertLessThan(
            ControllerEpoch(generation: 1, controllerID: high),
            ControllerEpoch(generation: 2, controllerID: low)
        )
        XCTAssertLessThan(
            ControllerEpoch(generation: 3, controllerID: low),
            ControllerEpoch(generation: 3, controllerID: high)
        )
    }

    func testInputActivationClampsBothBoundsAndPreservesInteriorValue() {
        let epoch = ControllerEpoch(generation: 1, controllerID: DeviceID())
        XCTAssertEqual(activation(position: -1, epoch: epoch).normalizedPosition, 0)
        XCTAssertEqual(activation(position: 0.4, epoch: epoch).normalizedPosition, 0.4)
        XCTAssertEqual(activation(position: 2, epoch: epoch).normalizedPosition, 1)
    }

    private func frame(controller: DeviceID, epoch: ControllerEpoch) -> InputFrame {
        InputFrame(
            workspaceID: WorkspaceID(),
            sessionID: SessionID(),
            controllerID: controller,
            epoch: epoch,
            sequence: 0,
            timestampNanos: 0,
            event: .flags(rawValue: 0)
        )
    }

    private func activation(position: Double, epoch: ControllerEpoch) -> InputActivation {
        InputActivation(
            sessionID: SessionID(),
            epoch: epoch,
            targetDisplayID: DisplayID(),
            entryEdge: .left,
            normalizedPosition: position
        )
    }
}
