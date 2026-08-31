import Foundation
import UniSpaceDomain

extension AppModel {
    var continuityCandidateDevices: [DeviceDescriptor] {
        devices
            .filter { $0.id != localDeviceID && connectedDevices.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var continuityTargetID: DeviceID? {
        if let currentControllerID,
           currentControllerID != localDeviceID,
           connectedDevices.contains(currentControllerID) {
            return currentControllerID
        }

        if let activeControlPeerID { return activeControlPeerID }

        if continuityCandidateDevices.count == 1 {
            return continuityCandidateDevices[0].id
        }
        return nil
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
