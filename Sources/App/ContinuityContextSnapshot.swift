import Combine
import UniSpaceApplication
import UniSpaceDomain

struct ContinuityContextSnapshot: Equatable {
    let workspace: WorkspaceSnapshot?
    let connectedDeviceIDs: Set<DeviceID>
    let controllerID: DeviceID?
    let controlSession: ControlSessionSnapshot
    let workspaceKeyRevision: UInt64
}

extension AppModel {
    var continuityContextPublisher: AnyPublisher<ContinuityContextSnapshot, Never> {
        Publishers.CombineLatest4(
            $workspace,
            $connectedDevices,
            $currentControllerID,
            $controlSessionSnapshot
        )
        .combineLatest($workspaceKeyRevision)
        .map { primary, workspaceKeyRevision in
            ContinuityContextSnapshot(
                workspace: primary.0,
                connectedDeviceIDs: primary.1,
                controllerID: primary.2,
                controlSession: primary.3,
                workspaceKeyRevision: workspaceKeyRevision
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
