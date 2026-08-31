import Foundation
import UniSpaceDomain

public enum ContinuityDestinationResolver {
    public static func resolve(
        localDeviceID: DeviceID,
        controllerID: DeviceID?,
        controlSession: ControlSessionSnapshot,
        devices: [DeviceDescriptor],
        connectedDeviceIDs: Set<DeviceID>
    ) -> DeviceID? {
        let compatibleConnectedPeers = Set(devices.lazy.filter {
            $0.id != localDeviceID &&
                connectedDeviceIDs.contains($0.id) &&
                supportsClipboard($0)
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

    private static func supportsClipboard(_ device: DeviceDescriptor) -> Bool {
        device.capabilities.contains(.clipboardTextV1) ||
            device.capabilities.contains(.clipboardURLV1)
    }
}
