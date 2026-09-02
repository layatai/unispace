import Foundation
import UniSpaceDomain

/// Immutable outbound connection ownership supplied to infrastructure.
/// Listening and already-authenticated inbound connections are unaffected.
public struct PeerConnectionPolicy: Sendable, Equatable {
    public let outboundPeerIDs: Set<DeviceID>

    public init(outboundPeerIDs: Set<DeviceID> = []) {
        self.outboundPeerIDs = outboundPeerIDs
    }

    public static let passive = PeerConnectionPolicy()

    public func ownsReconnect(to deviceID: DeviceID) -> Bool {
        outboundPeerIDs.contains(deviceID)
    }

    public static func macCanDial(_ peer: DeviceDescriptor?) -> Bool {
        peer.map { $0.platform != .windows } == true
    }
}

/// Keeps proactive macOS dialing on one workspace node. Windows peers are
/// outbound clients and are therefore never selected as macOS dial targets.
public enum ControlConnectionRoutingPolicy {
    public static func policy(
        localDeviceID: DeviceID,
        workspace: WorkspaceSnapshot,
        controllerID: DeviceID?
    ) -> PeerConnectionPolicy {
        let macPeers = workspace.devices.filter {
            $0.id != localDeviceID && PeerConnectionPolicy.macCanDial($0)
        }
        if let controllerID {
            return controllerID == localDeviceID
                ? PeerConnectionPolicy(outboundPeerIDs: Set(macPeers.map(\.id)))
                : .passive
        }

        let bootstrapOwner = workspace.devices
            .filter { PeerConnectionPolicy.macCanDial($0) }
            .map(\.id)
            .min()
        return bootstrapOwner == localDeviceID
            ? PeerConnectionPolicy(outboundPeerIDs: Set(macPeers.map(\.id)))
            : .passive
    }
}

public enum ControlSessionPhase: String, Sendable, Equatable {
    case idle
    case activating
    case controlling
    case receiving
}

public enum RealtimeConnectionRole: Sendable, Equatable {
    case dialer
    case listener
}

public struct ControlSessionSnapshot: Sendable, Equatable {
    public let phase: ControlSessionPhase
    public let peerID: DeviceID?
    public let latencyMilliseconds: Int?

    public init(
        phase: ControlSessionPhase,
        peerID: DeviceID? = nil,
        latencyMilliseconds: Int? = nil
    ) {
        self.phase = phase
        self.peerID = peerID
        self.latencyMilliseconds = latencyMilliseconds
    }

    public static let idle = ControlSessionSnapshot(phase: .idle)

    public var protectsInputLatency: Bool {
        phase == .activating || phase == .controlling || phase == .receiving
    }
}
