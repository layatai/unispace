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

    /// The peer participating in a live remote-control session. Unlike
    /// `continuityTargetID`, this intentionally has no single-connected-peer
    /// fallback, so an idle workspace does not unnecessarily throttle files.
    var activeControlPeerID: DeviceID? {
        let prefixes = ["Controlling ", "Controlled by "]
        for prefix in prefixes where statusMessage.hasPrefix(prefix) {
            let name = String(statusMessage.dropFirst(prefix.count))
            return connectedDevice(named: name)?.id
        }

        if statusMessage.hasPrefix("Slow "),
           let range = statusMessage.range(of: " connection to ") {
            let name = String(statusMessage[range.upperBound...])
            return connectedDevice(named: name)?.id
        }
        return nil
    }

    var isRemoteControlSessionActive: Bool {
        statusMessage.hasPrefix("Controlling ")
            || statusMessage.hasPrefix("Controlled by ")
            || statusMessage.hasPrefix("Slow ") && statusMessage.contains(" connection to ")
    }

    private func connectedDevice(named name: String) -> DeviceDescriptor? {
        continuityCandidateDevices.first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
