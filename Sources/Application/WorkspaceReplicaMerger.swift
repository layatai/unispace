import Foundation
import UniSpaceDomain

public enum WorkspaceReplicaMerger {
    public static func mergeDevice(
        _ current: DeviceDescriptor,
        with incoming: DeviceDescriptor,
        capabilitiesAreAuthoritative: Bool
    ) -> DeviceDescriptor {
        var merged = incoming
        if merged.displays.isEmpty { merged.displays = current.displays }
        merged.peerAddresses = mergeAddresses(current.peerAddresses, incoming.peerAddresses)
        if !capabilitiesAreAuthoritative {
            merged.capabilities = current.capabilities
            if merged.platform == .unknown { merged.platform = current.platform }
        }
        return merged
    }

    public static func mergeSnapshot(
        _ current: WorkspaceSnapshot,
        with incoming: WorkspaceSnapshot
    ) -> WorkspaceSnapshot? {
        guard incoming.id == current.id else { return nil }

        let currentDevices = Dictionary(uniqueKeysWithValues: current.devices.map { ($0.id, $0) })
        let incomingIDs = Set(incoming.devices.map(\.id))
        var merged = current
        merged.devices = incoming.devices.map { incomingDevice in
            guard let currentDevice = currentDevices[incomingDevice.id] else { return incomingDevice }
            return mergeDevice(
                currentDevice,
                with: incomingDevice,
                capabilitiesAreAuthoritative: false
            )
        }
        merged.devices.append(contentsOf: current.devices.filter { !incomingIDs.contains($0.id) })
        merged.topology = incoming.topology
        merged.generation = max(current.generation, incoming.generation)
        return merged
    }

    public static func mergeAddresses(
        _ first: [PeerAddress],
        _ second: [PeerAddress]
    ) -> [PeerAddress] {
        Array(Set(first + second)).sorted { $0.host < $1.host }
    }
}
