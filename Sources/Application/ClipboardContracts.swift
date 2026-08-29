import Foundation
import UniSpaceDomain

public struct ClipboardObservation: Sendable, Equatable {
    public let changeCount: Int
    public let representations: [ClipboardRepresentation]

    public init(changeCount: Int, representations: [ClipboardRepresentation]) {
        self.changeCount = changeCount
        self.representations = representations
    }
}

@MainActor
public protocol ClipboardService: AnyObject, Sendable {
    func events() -> AsyncStream<ClipboardObservation>
    func stop()
    func apply(_ payload: ClipboardPayload)
}

public enum ClipboardTransportEvent: Sendable, Equatable {
    case connected(DeviceID)
    case disconnected(DeviceID)
    case update(DeviceID, ClipboardEnvelope)
    case failure(DeviceID?)
}

public protocol ClipboardTransport: Sendable {
    func start(
        localDevice: DeviceDescriptor,
        workspace: WorkspaceSnapshot,
        key: Data
    ) async throws
    func stop() async
    func events() -> AsyncStream<ClipboardTransportEvent>
    func send(_ envelope: ClipboardEnvelope, to deviceID: DeviceID) async throws
}
