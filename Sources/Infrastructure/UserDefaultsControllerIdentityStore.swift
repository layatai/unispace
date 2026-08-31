import Foundation
import UniSpaceApplication
import UniSpaceDomain

public struct UserDefaultsControllerIdentityStore: ControllerIdentityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "connection.controller"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func controllerID(for workspaceID: WorkspaceID) -> DeviceID? {
        guard let value = defaults.string(forKey: key(for: workspaceID)),
              let uuid = UUID(uuidString: value) else { return nil }
        return DeviceID(rawValue: uuid)
    }

    public func setControllerID(_ deviceID: DeviceID?, for workspaceID: WorkspaceID) {
        let key = key(for: workspaceID)
        if let deviceID {
            defaults.set(deviceID.rawValue.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(for workspaceID: WorkspaceID) -> String {
        "\(keyPrefix).\(workspaceID.rawValue.uuidString.lowercased())"
    }
}
