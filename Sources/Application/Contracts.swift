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
    var isSuppressionEnabled: Bool { get }
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

public protocol ControllerIdentityStore: Sendable {
    func controllerID(for workspaceID: WorkspaceID) -> DeviceID?
    func setControllerID(_ deviceID: DeviceID?, for workspaceID: WorkspaceID)
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

public enum TransportKind: String, Codable, Equatable, Sendable {
    case tcp
    case quic
}

public enum ConnectionHealth: String, Codable, Equatable, Sendable {
    case connecting
    case healthy
    case degraded
    case reconnecting
    case disconnected
}

public struct ConnectionSnapshot: Codable, Equatable, Sendable {
    public let health: ConnectionHealth
    public let transport: TransportKind
    public let latencyMilliseconds: Int?
    public let detail: String?

    public init(
        health: ConnectionHealth,
        transport: TransportKind,
        latencyMilliseconds: Int? = nil,
        detail: String? = nil
    ) {
        self.health = health
        self.transport = transport
        self.latencyMilliseconds = latencyMilliseconds
        self.detail = detail
    }
}

public enum PeerEvent: Sendable, Equatable {
    case discovered(DeviceDescriptor)
    case lost(DeviceID)
    case connected(DeviceID)
    case workspaceUpgradeRequired(DeviceID)
    case disconnected(DeviceID)
    case control(DeviceID, ControlEnvelope)
    case input(DeviceID, InputFrame)
    case realtimeInput(DeviceID, RealtimePointerFrame)
    case health(DeviceID?, ConnectionSnapshot)
    case failure(DeviceID?, String)
}

public protocol PeerTransport: Sendable {
    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) async throws
    func stop() async
    func updateConnectionPolicy(_ policy: PeerConnectionPolicy)
    func setRealtimePeer(_ deviceID: DeviceID?)
    func reconnect(to deviceID: DeviceID)
    func events() -> AsyncStream<PeerEvent>
    func send(_ envelope: ControlEnvelope, to deviceID: DeviceID) async throws
    func send(_ frame: InputFrame, to deviceID: DeviceID) async throws
    @discardableResult
    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool
}

public extension PeerTransport {
    func updateConnectionPolicy(_ policy: PeerConnectionPolicy) {}
    func setRealtimePeer(_ deviceID: DeviceID?) {}

    @discardableResult
    func sendRealtime(_ frame: RealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        try await send(frame.reliableFallback, to: deviceID)
        return false
    }
}

public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(for duration: Duration) async throws
}

public extension MonotonicClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
