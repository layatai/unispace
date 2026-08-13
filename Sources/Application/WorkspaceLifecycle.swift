import Foundation
import UniSpaceDomain

public enum LeaveWorkspaceResult: Equatable, Sendable {
    case complete
    case trustKeyCleanupFailed
}

/// Removes this Mac's local membership without changing the workspace on
/// other Macs. Persistent workspace state is removed first so a Keychain
/// cleanup failure cannot prevent the app from returning to onboarding.
public struct WorkspaceLifecycle: Sendable {
    private let workspaceStore: any WorkspaceStore
    private let trustStore: any TrustStore

    public init(workspaceStore: any WorkspaceStore, trustStore: any TrustStore) {
        self.workspaceStore = workspaceStore
        self.trustStore = trustStore
    }

    public func leave(workspaceID: WorkspaceID) throws -> LeaveWorkspaceResult {
        try workspaceStore.remove()
        do {
            try trustStore.removeWorkspaceKey(for: workspaceID)
            return .complete
        } catch {
            return .trustKeyCleanupFailed
        }
    }
}
