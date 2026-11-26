import CryptoKit
import Foundation
import LocalAuthentication

/// The key that protects hidden items. Its private half never leaves this Mac.
///
/// Hidden items are sealed to the public key, so saving a new one needs no Touch ID. Opening
/// one needs the private key, and the Secure Enclave releases it only after Touch ID or the
/// Mac password. History copied to another Mac keeps its hidden items sealed.
protocol HiddenKey {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret
}

enum HiddenKeyError: LocalizedError {
    case secureEnclaveUnavailable

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable: L("This Mac has no Secure Enclave, so hidden items cannot be protected.")
        }
    }
}

/// A P-256 key in the Secure Enclave. Each use needs user presence (Touch ID or the Mac password).
/// The Keychain holds only its blob, which only this Mac's Secure Enclave can use.
struct SecureEnclaveHiddenKey: HiddenKey {
    static let account = "hidden-items-key"

    let blob: Data
    let publicKey: P256.KeyAgreement.PublicKey

    static func loadOrCreate(keyStore: KeyStore) throws -> SecureEnclaveHiddenKey {
        if let blob = try keyStore.load(account: account) {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
            return SecureEnclaveHiddenKey(blob: blob, publicKey: key.publicKey)
        }
        guard SecureEnclave.isAvailable else { throw HiddenKeyError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try keyStore.save(key.dataRepresentation, account: account)
        return SecureEnclaveHiddenKey(blob: key.dataRepresentation, publicKey: key.publicKey)
    }

    func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

/// A software key for tests: same format, no Secure Enclave.
struct SoftwareHiddenKey: HiddenKey {
    let privateKey = P256.KeyAgreement.PrivateKey()
    var publicKey: P256.KeyAgreement.PublicKey { privateKey.publicKey }

    func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey, context: LAContext?) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

/// Sealed format of a hidden item: "CLPS", a version byte, a one-time P-256 public key
/// (65 bytes, X9.63), then the AES-256-GCM sealed box. The AES key comes from ECDH between the
/// one-time key and the hidden key, through HKDF-SHA256.
enum SealedSecret {
    static let magic = Data("CLPS".utf8)
    static let version: UInt8 = 1
    private static let info = Data("com.iokoda.clipboard.hidden.v1".utf8)

    static func seal(_ plaintext: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = symmetricKey(shared, ephemeral: ephemeral.publicKey, recipient: recipient)
        let header = magic + [version] + ephemeral.publicKey.x963Representation
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: header).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return header + combined
    }

    static func open(_ sealed: Data, with hiddenKey: HiddenKey, context: LAContext?) throws -> Data {
        let headerLength = magic.count + 1 + 65
        guard sealed.count > headerLength, sealed.prefix(magic.count) == magic,
              sealed[sealed.startIndex + magic.count] == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let header = sealed.prefix(headerLength)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: header.suffix(65))
        let shared = try hiddenKey.sharedSecret(with: ephemeral, context: context)
        let key = symmetricKey(shared, ephemeral: ephemeral, recipient: hiddenKey.publicKey)
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(headerLength))
        return try AES.GCM.open(box, using: key, authenticating: header)
    }

    private static func symmetricKey(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey,
                                     recipient: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.x963Representation + recipient.x963Representation,
            sharedInfo: info,
            outputByteCount: 32
        )
    }
}
