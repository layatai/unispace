import Foundation
import UniSpaceDomain

public enum PermissionKind: String, CaseIterable, Sendable {
    case inputMonitoring
    case postEvents
    case localNetwork
}

public enum PermissionState: String, Sendable {
    case unknown
    case denied
    case granted
}

public protocol PermissionService: Sendable {
    func state(for permission: PermissionKind) -> PermissionState
    @discardableResult func request(_ permission: PermissionKind) -> Bool
}

public protocol DisplayCatalog: Sendable {
    func currentDisplays(for deviceID: DeviceID) -> [DisplayDescriptor]
}

public protocol TailnetAddressProviding: Sendable {
    func currentAddresses() -> [PeerAddress]
}

public protocol InputCapture: Sendable {
    func start(handler: @escaping @Sendable (InputEvent) -> Bool) throws
    func stop()
    func setSuppressionEnabled(_ enabled: Bool)
}

public protocol InputInjector: Sendable {
    func activate(on display: DisplayDescriptor, enteringFrom edge: DisplayEdge, normalizedPosition: Double)
    func inject(_ event: InputEvent)
    func releaseAll()
}

public protocol WorkspaceStore: Sendable {
    func load() throws -> WorkspaceSnapshot?
    func save(_ workspace: WorkspaceSnapshot) throws
    func remove() throws
}

public protocol TrustStore: Sendable {
    func workspaceKey(for workspaceID: WorkspaceID) throws -> Data?
    func storeWorkspaceKey(_ key: Data, for workspaceID: WorkspaceID) throws
    func removeWorkspaceKey(for workspaceID: WorkspaceID) throws
}

public protocol LoginItemController: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public enum PeerEvent: Sendable, Equatable {
    case discovered(DeviceDescriptor)
    case lost(DeviceID)
    case connected(DeviceID)
    case disconnected(DeviceID)
    case control(DeviceID, ControlEnvelope)
    case input(DeviceID, InputFrame)
    case failure(DeviceID?, String)
}

public protocol PeerTransport: Sendable {
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws
    func stop() async
    func events() -> AsyncStream<PeerEvent>
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws
}

public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
