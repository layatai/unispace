import Foundation
import UniSpaceDomain

public enum ContinuityDestinationResolver {
    /// Why `resolve` picked (or did not pick) a destination. Used for
    /// diagnostics only; it carries no device content.
    public enum Reason: String, Sendable {
        case remoteController = "remote controller"
        case activeControlSession = "active control session"
        case onlyConnectedPeer = "only connected compatible peer"
        case noCompatiblePeer = "no connected compatible peer"
        case ambiguous = "several connected compatible peers and no active session"
    }

    public static func resolve(
        localDeviceID: DeviceID,
        controllerID: DeviceID?,
        controlSession: ControlSessionSnapshot,
        devices: [DeviceDescriptor],
        connectedDeviceIDs: Set<DeviceID>,
        requiredCapabilities: Set<DeviceCapability> = []
    ) -> DeviceID? {
        explain(
            localDeviceID: localDeviceID,
            controllerID: controllerID,
            controlSession: controlSession,
            devices: devices,
            connectedDeviceIDs: connectedDeviceIDs,
            requiredCapabilities: requiredCapabilities
        ).destination
    }

    public static func explain(
        localDeviceID: DeviceID,
        controllerID: DeviceID?,
        controlSession: ControlSessionSnapshot,
        devices: [DeviceDescriptor],
        connectedDeviceIDs: Set<DeviceID>,
        requiredCapabilities: Set<DeviceCapability> = []
    ) -> (destination: DeviceID?, reason: Reason) {
        let compatibleConnectedPeers = Set(devices.lazy.filter {
            $0.id != localDeviceID &&
                connectedDeviceIDs.contains($0.id) &&
                (requiredCapabilities.isEmpty ||
                    !$0.capabilities.isDisjoint(with: requiredCapabilities))
        }.map(\.id))

        if let controllerID,
           controllerID != localDeviceID,
           compatibleConnectedPeers.contains(controllerID) {
            return (controllerID, .remoteController)
        }

        if controlSession.protectsInputLatency,
           let peerID = controlSession.peerID,
           compatibleConnectedPeers.contains(peerID) {
            return (peerID, .activeControlSession)
        }

        switch compatibleConnectedPeers.count {
        case 0: return (nil, .noCompatiblePeer)
        case 1: return (compatibleConnectedPeers.first, .onlyConnectedPeer)
        default: return (nil, .ambiguous)
        }
    }
}
