import Foundation
import UniSpaceDomain

public enum ContinuityDestinationResolver {
    public static func resolve(
        localDeviceID: DeviceID,
        controllerID: DeviceID?,
        controlSession: ControlSessionSnapshot,
        devices: [DeviceDescriptor],
        connectedDeviceIDs: Set<DeviceID>,
        requiredCapabilities: Set<DeviceCapability> = []
    ) -> DeviceID? {
        let compatibleConnectedPeers = Set(devices.lazy.filter {
            $0.id != localDeviceID &&
                connectedDeviceIDs.contains($0.id) &&
                (requiredCapabilities.isEmpty ||
                    !$0.capabilities.isDisjoint(with: requiredCapabilities))
        }.map(\.id))

        if let controllerID,
           controllerID != localDeviceID,
           compatibleConnectedPeers.contains(controllerID) {
            return controllerID
        }

        if controlSession.protectsInputLatency,
           let peerID = controlSession.peerID,
           compatibleConnectedPeers.contains(peerID) {
            return peerID
        }

        return compatibleConnectedPeers.count == 1
            ? compatibleConnectedPeers.first
            : nil
    }
}
