import CoreGraphics
import Foundation
import UniSpaceApplication

public struct SystemPermissionService: PermissionService {
    public init() {}

    public func state(for permission: PermissionKind) -> PermissionState {
        switch permission {
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .denied
        case .postEvents:
            CGPreflightPostEventAccess() ? .granted : .denied
        case .localNetwork:
            .unknown
        }
    }

    @discardableResult
    public func request(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .inputMonitoring:
            CGRequestListenEventAccess()
        case .postEvents:
            CGRequestPostEventAccess()
        case .localNetwork:
            false
        }
    }
}
