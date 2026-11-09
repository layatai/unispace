import CryptoKit
import Foundation
import Network
import UniSpaceApplication
import UniSpaceDomain

/// Two independent authenticated connections: small control packets and bounded
/// video access units. No video bytes enter the existing control/content lanes.
/// Main-actor confinement plus read-one/handle-one backpressure bounds delivery.
@MainActor
public final class SeamlessWindowConnection {
    public enum Lane: String, Codable, Sendable { case control, video }
    private struct Hello: Codable {
        let version: Int
        let workspace: WorkspaceID
        let device: DeviceID
        let lane: Lane
        let nonce: Data
        let proof: Data
    }

    public let lane: Lane
    public private(set) var peer: DeviceID?
    public var onReady: ((DeviceID) -> Void)?
    public var onPacket: ((DeviceID, Data) -> Void)?
    public var onClosed: (() -> Void)?
    public private(set) var isSending = false
    private let connection: NWConnection
    private let workspace: WorkspaceID
    private let local: DeviceID
    private let allowed: Set<DeviceID>
    private let expected: DeviceID?
    private let rootKey: SymmetricKey
    private let nonce: Data
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sequence: UInt64 = 0
    private var lastSequence: UInt64?
    private var closed = false
    private var timeout: Task<Void, Never>?
    private var sendTimeout: Task<Void, Never>?
    private var outbound: [Data] = []

    public init(connection: NWConnection, lane: Lane, workspace: WorkspaceID,
                local: DeviceID, allowed: Set<DeviceID>, expected: DeviceID?, key: Data) throws {
        guard key.count == 32, !allowed.contains(local) else { throw SeamlessWindowError.invalidMessage }
        self.connection = connection; self.lane = lane; self.workspace = workspace
        self.local = local; self.allowed = allowed; self.expected = expected
        rootKey = SymmetricKey(data: key)
        nonce = PairingCryptoSession.randomData(count: 32)
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.hello(); self.readHeader()
                case .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.peer == nil else { return }
            self.close()
        }
        connection.start(queue: DispatchQueue(label: "com.layatai.unispace.window.\(lane.rawValue)", qos: .userInitiated))
    }

    /// Returns false for backpressure. Dropping an encoded video unit requires
    /// the caller to force an IDR before sending dependent frames again.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        guard !closed, sendKey != nil, data.count <= maximumPayload else { return false }
        if lane == .video && isSending { return false }
        guard outbound.count < 64 else { close(); return false }
        outbound.append(data)
        drain()
        return true
    }

    public func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel(); sendTimeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        sendKey = nil; receiveKey = nil; outbound.removeAll()
        isSending = false
        let callback = onClosed
        onClosed = nil; onReady = nil; onPacket = nil
        callback?()
    }

    private var maximumPayload: Int {
        lane == .control ? SeamlessWindowLimits.maximumControlBytes : SeamlessWindowLimits.maximumFrameBytes + 16_384
    }

    private func proofData(device: DeviceID, nonce: Data) -> Data {
        Data("UniSpace seamless v1|\(lane.rawValue)|\(workspace)|\(device)|".utf8) + nonce
    }

    private func hello() {
        let value = Hello(version: 1, workspace: workspace, device: local, lane: lane, nonce: nonce,
                          proof: Data(HMAC<SHA256>.authenticationCode(for: proofData(device: local, nonce: nonce), using: rootKey)))
        do {
            let data = try PropertyListEncoder().encode(value)
            writePacket(kind: 0, data: data) { [weak self] error in if error { self?.close() } }
        } catch { close() }
    }

    private func authenticate(_ data: Data) throws {
        guard peer == nil, data.count <= 4_096 else { throw SeamlessWindowError.invalidMessage }
        let value = try PropertyListDecoder().decode(Hello.self, from: data)
        guard value.version == 1, value.workspace == workspace, value.lane == lane,
              allowed.contains(value.device), expected == nil || expected == value.device,
              value.nonce.count == 32, value.proof.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(value.proof,
                  authenticating: proofData(device: value.device, nonce: value.nonce), using: rootKey) else {
            throw SeamlessWindowError.permissionDenied
        }
        let first = local < value.device
        let salt = first ? nonce + value.nonce : value.nonce + nonce
        let context = "UniSpace seamless v1|\(lane.rawValue)|\(workspace)|"
        func derive(from: DeviceID, to: DeviceID) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: rootKey, salt: salt,
                info: Data("\(context)\(from)|\(to)".utf8), outputByteCount: 32)
        }
        sendKey = derive(from: local, to: value.device)
        receiveKey = derive(from: value.device, to: local)
        peer = value.device
        timeout?.cancel()
        onReady?(value.device)
    }

    private func drain() {
        guard !closed, !isSending, !outbound.isEmpty, let sendKey else { return }
        guard sequence < UInt64.max else { close(); return }
        let payload = outbound.removeFirst()
        var value = sequence.bigEndian
        var plaintext = withUnsafeBytes(of: &value) { Data($0) }
        plaintext.append(payload)
        sequence += 1
        do {
            let sealed = try ChaChaPoly.seal(plaintext, using: sendKey).combined
            isSending = true
            // A slow peer cannot accumulate seconds of stale video in a stream.
            sendTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.close()
            }
            writePacket(kind: 1, data: sealed) { [weak self] error in
                guard let self, !self.closed else { return }
                self.sendTimeout?.cancel()
                self.isSending = false
                if error { self.close() } else { self.drain() }
            }
        } catch { close() }
    }

    private func writePacket(kind: UInt8, data: Data, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        var length = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(kind); packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { error in
            Task { @MainActor in completion(error != nil) }
        })
    }

    private func readHeader() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                guard error == nil, !complete, let data, data.count == 5 else { self.close(); return }
                let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                let kind = data.last!
                let limit = kind == 0 ? 4_096 : self.maximumPayload + 36
                guard kind <= 1, length > 0, length <= limit,
                      (self.peer == nil) == (kind == 0) else { self.close(); return }
                self.readBody(length: length, kind: kind)
            }
        }
    }

    private func readBody(length: Int, kind: UInt8) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == length else { self.close(); return }
                do {
                    if kind == 0 { try self.authenticate(data) }
                    else {
                        guard let key = self.receiveKey, let peer = self.peer else { throw SeamlessWindowError.unavailable }
                        let clear = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
                        guard clear.count >= 8 else { throw SeamlessWindowError.invalidMessage }
                        let sequence = clear.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                        guard self.lastSequence.map({ sequence > $0 }) ?? (sequence == 0) else {
                            throw SeamlessWindowError.staleLease
                        }
                        self.lastSequence = sequence
                        self.onPacket?(peer, Data(clear.dropFirst(8)))
                    }
                    if complete { self.close() } else { self.readHeader() }
                } catch { self.close() }
            }
        }
    }
}
