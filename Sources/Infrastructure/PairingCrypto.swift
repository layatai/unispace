import CryptoKit
import Foundation
import Security

public enum PairingCryptoError: Error, Equatable {
    case invalidPublicKey
    case invalidSealedPayload
}

public struct PairingOffer: Codable, Equatable, Sendable {
    public let publicKey: Data
    public let nonce: Data

    public init(publicKey: Data, nonce: Data) {
        self.publicKey = publicKey
        self.nonce = nonce
    }
}

public struct SealedWorkspaceCredential: Codable, Equatable, Sendable {
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

public final class PairingCryptoSession: @unchecked Sendable {
    private let privateKey: P256.KeyAgreement.PrivateKey
    public let offer: PairingOffer

    public init() {
        let privateKey = P256.KeyAgreement.PrivateKey()
        self.privateKey = privateKey
        self.offer = PairingOffer(
            publicKey: privateKey.publicKey.x963Representation,
            nonce: Self.randomData(count: 32)
        )
    }

    public func shortAuthenticationCode(peerOffer: PairingOffer) throws -> String {
        let key = try derivedKey(peerOffer: peerOffer)
        return key.withUnsafeBytes { bytes in
            let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return String(format: "%06u", value % 1_000_000)
        }
    }

    public func sealWorkspaceKey(_ workspaceKey: Data, peerOffer: PairingOffer) throws -> SealedWorkspaceCredential {
        let box = try ChaChaPoly.seal(workspaceKey, using: derivedKey(peerOffer: peerOffer))
        return SealedWorkspaceCredential(combined: box.combined)
    }

    public func openWorkspaceKey(_ credential: SealedWorkspaceCredential, peerOffer: PairingOffer) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: credential.combined) else {
            throw PairingCryptoError.invalidSealedPayload
        }
        return try ChaChaPoly.open(box, using: derivedKey(peerOffer: peerOffer))
    }

    private func derivedKey(peerOffer: PairingOffer) throws -> SymmetricKey {
        guard let peerPublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: peerOffer.publicKey) else {
            throw PairingCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let localFirst = offer.publicKey.lexicographicallyPrecedes(peerOffer.publicKey)
        let transcript = localFirst
            ? offer.publicKey + peerOffer.publicKey + offer.nonce + peerOffer.nonce
            : peerOffer.publicKey + offer.publicKey + peerOffer.nonce + offer.nonce
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("UniSpace pairing v1".utf8),
            outputByteCount: 32
        )
    }

    public static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }
}
