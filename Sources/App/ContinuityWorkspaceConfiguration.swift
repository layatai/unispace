import Foundation
import UniSpaceDomain

/// Complete trust and routing input for a continuity service. Comparing the
/// whole value ensures peer/address edits and workspace-key rotation restart
/// content channels even when the workspace ID and generation stay unchanged.
struct ContinuityWorkspaceConfiguration: Equatable {
    let localDevice: DeviceDescriptor
    let workspace: WorkspaceSnapshot
    let key: Data

    init(
        workspace: WorkspaceSnapshot,
        localDevice: DeviceDescriptor,
        key: Data,
        capabilities: Set<DeviceCapability>
    ) {
        var localDevice = localDevice
        localDevice.capabilities.formUnion(capabilities)
        var workspace = workspace
        workspace.updateDevice(localDevice)
        self.localDevice = localDevice
        self.workspace = workspace
        self.key = key
    }
}
