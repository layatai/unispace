import Foundation
import UniSpaceDomain

/// Limits control routing to authenticated devices that still belong to the
/// trusted workspace. Activation acknowledgement is negotiated per peer, so
/// legacy peers remain routable through the coordinator's compatibility path.
public enum ControlRoutingPolicy {
    public static func availableDeviceIDs(
        connectedDeviceIDs: Set<DeviceID>,
        devices: [DeviceDescriptor]
    ) -> Set<DeviceID> {
        connectedDeviceIDs.intersection(devices.map(\.id))
    }
}
