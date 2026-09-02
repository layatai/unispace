import Foundation
import UniSpaceApplication
import UniSpaceDomain

extension AppModel {
    var continuityCandidateDevices: [DeviceDescriptor] {
        devices
            .filter { $0.id != localDeviceID && connectedDevices.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var continuityTargetID: DeviceID? {
        ContinuityDestinationResolver.resolve(
            localDeviceID: localDeviceID,
            controllerID: currentControllerID,
            controlSession: controlSessionSnapshot,
            devices: devices,
            connectedDeviceIDs: connectedDevices
        )
    }

    var activeControlPeerID: DeviceID? {
        guard controlSessionSnapshot.protectsInputLatency,
              let peerID = controlSessionSnapshot.peerID,
              connectedDevices.contains(peerID) else { return nil }
        return peerID
    }

    var isRemoteControlSessionActive: Bool {
        controlSessionSnapshot.protectsInputLatency
    }
}
