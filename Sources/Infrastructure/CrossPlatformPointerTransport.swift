import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

/// Authenticated UDP lane for replaceable pointer state sent to Windows receivers.
/// Windows initiates the flow, so the receiver does not need an inbound listener.
final class CrossPlatformPointerTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.layatai.unispace.windows-pointer", qos: .userInteractive)
    private let lock = NSLock()
    private var localDevice: DeviceDescriptor?
    private var workspaceID: WorkspaceID?
    private var key: Data?
    private var listener: NWListener?
    private var connections: [DeviceID: SecurePeerConnection] = [:]
    private var pending: [ObjectIdentifier: SecurePeerConnection] = [:]

    func start(localDevice: DeviceDescriptor, workspace: WorkspaceSnapshot, key: Data) throws {
        stop()
        let listener = try NWListener(using: .udp, on: NetworkPeerTransport.crossPlatformPointerPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        lock.withLock {
            self.localDevice = localDevice
            workspaceID = workspace.id
            self.key = key
            self.listener = listener
        }
        listener.start(queue: queue)
    }

    func stop() {
        let values = lock.withLock { () -> (NWListener?, [SecurePeerConnection]) in
            let values = (listener, Array(connections.values) + Array(pending.values))
            listener = nil
            connections.removeAll()
            pending.removeAll()
            localDevice = nil
            workspaceID = nil
            key = nil
            return values
        }
        values.0?.cancel()
        values.1.forEach { $0.cancel() }
    }

    func send(_ frame: PortableRealtimePointerFrame, to deviceID: DeviceID) async throws -> Bool {
        guard let connection = lock.withLock({ connections[deviceID] }) else { return false }
        try await connection.send(WireFrameCodec.encodePortableRealtimePointer(frame))
        return true
    }

    private func accept(_ connection: NWConnection) {
        guard let configuration = lock.withLock({ () -> (DeviceID, WorkspaceID, Data)? in
            guard let localDevice, let workspaceID, let key else { return nil }
            return (localDevice.id, workspaceID, key)
        }) else {
            connection.cancel()
            return
        }
        let managed = SecurePeerConnection(
            connection: connection,
            localDeviceID: configuration.0,
            workspaceID: configuration.1,
            workspaceKey: configuration.2,
            expectedDeviceID: nil,
            isOutbound: false,
            transportKind: .tcp,
            isDatagram: true,
            securityProfile: .pointerV2
        )
        let objectID = ObjectIdentifier(managed)
        lock.withLock { pending[objectID] = managed }
        managed.authenticatedHandler = { [weak self, weak managed] deviceID in
            guard let self, let managed else { return }
            let replaced = self.lock.withLock { () -> SecurePeerConnection? in
                self.pending.removeValue(forKey: objectID)
                return self.connections.updateValue(managed, forKey: deviceID)
            }
            replaced?.cancel()
        }
        managed.frameHandler = { _, _ in
            // Windows peers are receiver-only; input on this lane is ignored.
        }
        managed.stateHandler = { [weak self, weak managed] state in
            guard let self, let managed, state == .cancelled || Self.isFailure(state) else { return }
            self.lock.withLock {
                self.pending.removeValue(forKey: objectID)
                if let deviceID = managed.deviceID, self.connections[deviceID] === managed {
                    self.connections.removeValue(forKey: deviceID)
                }
            }
        }
        connection.start(queue: queue)
    }

    private static func isFailure(_ state: NWConnection.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
