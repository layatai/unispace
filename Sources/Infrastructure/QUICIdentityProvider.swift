import Foundation
import Security

enum QUICIdentityError: Error {
    case keyGenerationFailed
    case publicKeyUnavailable
    case certificateCreationFailed
    case keychainFailure(OSStatus)
    case identityUnavailable
    case signingFailed
}

enum QUICIdentityProvider {
    private static let lock = NSLock()
    private static let keyTag = Data("com.layatai.unispace.quic-identity-key".utf8)
    private static let certificateLabel = "UniSpace QUIC Transport Identity"
    nonisolated(unsafe) private static var cachedIdentity: sec_identity_t?

    static func identity() throws -> sec_identity_t {
        try lock.withLock {
            if let cachedIdentity { return cachedIdentity }
            let privateKey = try loadOrCreatePrivateKey()
            let certificate = try loadOrCreateCertificate(privateKey: privateKey)
            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
            guard status == errSecSuccess, let identity,
                  let protocolIdentity = sec_identity_create(identity) else {
                throw QUICIdentityError.identityUnavailable
            }
            cachedIdentity = protocolIdentity
            return protocolIdentity
        }
    }

    private static func loadOrCreatePrivateKey() throws -> SecKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as! SecKey? { return key }
        guard status == errSecItemNotFound else { throw QUICIdentityError.keychainFailure(status) }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw QUICIdentityError.keyGenerationFailed
        }
        return key
    }

    private static func loadOrCreateCertificate(privateKey: SecKey) throws -> SecCertificate {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let certificate = result as! SecCertificate? { return certificate }
        guard status == errSecItemNotFound else { throw QUICIdentityError.keychainFailure(status) }

        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw QUICIdentityError.publicKeyUnavailable
        }
        let certificateData = try makeCertificate(publicKey: publicBytes, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw QUICIdentityError.certificateCreationFailed
        }
        let addStatus = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecValueRef: certificate
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw QUICIdentityError.keychainFailure(addStatus)
        }
        return certificate
    }

    private static func makeCertificate(publicKey: Data, privateKey: SecKey) throws -> Data {
        let signatureAlgorithm = DER.sequence([
            DER.objectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        ])
        let commonName = DER.sequence([
            DER.set([
                DER.sequence([
                    DER.objectIdentifier([0x55, 0x04, 0x03]),
                    DER.utf8String("UniSpace Local Transport")
                ])
            ])
        ])
        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([
                DER.objectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
                DER.objectIdentifier([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            ]),
            DER.bitString(publicKey)
        ])
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[serial.startIndex] &= 0x7F
        let now = Date()
        let tbsCertificate = DER.sequence([
            DER.explicit(tag: 0, DER.integer(Data([2]))),
            DER.integer(serial),
            signatureAlgorithm,
            commonName,
            DER.sequence([
                DER.generalizedTime(now.addingTimeInterval(-86_400)),
                DER.generalizedTime(now.addingTimeInterval(10 * 365 * 86_400))
            ]),
            commonName,
            subjectPublicKeyInfo
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            throw QUICIdentityError.signingFailed
        }
        return DER.sequence([tbsCertificate, signatureAlgorithm, DER.bitString(signature)])
    }
}

private enum DER {
    static func sequence(_ values: [Data]) -> Data { item(tag: 0x30, content: joined(values)) }
    static func set(_ values: [Data]) -> Data { item(tag: 0x31, content: joined(values)) }
    static func integer(_ value: Data) -> Data {
        var bytes = value.drop { $0 == 0 }
        if bytes.isEmpty { bytes = Data.SubSequence([0]) }
        var content = Data(bytes)
        if content.first.map({ $0 & 0x80 != 0 }) == true { content.insert(0, at: 0) }
        return item(tag: 0x02, content: content)
    }
    static func objectIdentifier(_ bytes: [UInt8]) -> Data { item(tag: 0x06, content: Data(bytes)) }
    static func utf8String(_ value: String) -> Data { item(tag: 0x0C, content: Data(value.utf8)) }
    static func bitString(_ value: Data) -> Data { item(tag: 0x03, content: Data([0]) + value) }
    static func explicit(tag: UInt8, _ value: Data) -> Data { item(tag: 0xA0 | tag, content: value) }
    static func generalizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return item(tag: 0x18, content: Data(formatter.string(from: date).utf8))
    }

    private static func joined(_ values: [Data]) -> Data {
        values.reduce(into: Data()) { $0.append($1) }
    }

    private static func item(tag: UInt8, content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
