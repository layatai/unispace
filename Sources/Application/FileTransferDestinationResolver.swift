import Foundation
import UniSpaceDomain

public enum FileTransferDestinationResolver {
    public static func resolve(
        selectedDeviceID: DeviceID?,
        continuityTargetID: DeviceID?,
        candidates: [DeviceDescriptor],
        connectedDeviceIDs: Set<DeviceID>
    ) -> DeviceID? {
        if let selectedDeviceID, connectedDeviceIDs.contains(selectedDeviceID) {
            return selectedDeviceID
        }
        if let continuityTargetID, connectedDeviceIDs.contains(continuityTargetID) {
            return continuityTargetID
        }
        return candidates
            .filter { connectedDeviceIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            .first?.id
    }
}
