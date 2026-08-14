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

        let prefix = "Controlling "
        if statusMessage.hasPrefix(prefix) {
            let name = String(statusMessage.dropFirst(prefix.count))
            if let target = continuityCandidateDevices.first(where: { $0.name == name }) {
                return target.id
            }
        }

        if continuityCandidateDevices.count == 1 {
            return continuityCandidateDevices[0].id
        }
        return nil
    }
}
