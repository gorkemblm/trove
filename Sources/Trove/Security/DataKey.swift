import CryptoKit
import Foundation

/// The random 256-bit key that protects one history folder.
///
/// Two keys are derived from it with HKDF-SHA256, one for each purpose:
/// - the SQLCipher key of the database (raw key, so opening needs no slow key derivation),
/// - the AES-256-GCM key of the image files.
struct DataKey: Sendable {
    let raw: Data

    init(raw: Data) {
        precondition(raw.count == Self.byteCount, "A data key has 32 bytes")
        self.raw = raw
    }

    static let byteCount = 32

    static func random() -> DataKey {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        precondition(status == errSecSuccess, "The system random generator failed")
        return DataKey(raw: bytes)
    }

    private func derive(_ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: raw),
            salt: Data("com.iokoda.clipboard".utf8),
            info: Data(purpose.utf8),
            outputByteCount: 32
        )
    }

    /// SQLCipher raw key literal: `x'<64 hex digits>'`.
    var databasePassphrase: String {
        let bytes = derive("database.v1").withUnsafeBytes { Data($0) }
        return "x'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
    }

    var imageKey: SymmetricKey { derive("images.v1") }

    /// HMAC key that links a manually hidden item to later copies of the same content.
    var hiddenMatchKey: SymmetricKey { derive("hidden-match.v1") }
}

/// Encrypted file format for images: "CLPE", a version byte, then the AES-GCM sealed box
/// (12-byte nonce, ciphertext, 16-byte tag).
enum EncryptedFile {
    static let magic = Data("CLPE".utf8)
    static let version: UInt8 = 1
    static let fileExtension = "enc"

    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        let header = magic + [version]
        let box = try AES.GCM.seal(data, using: key, authenticating: header)
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return header + combined
    }

    static func open(_ file: Data, with key: SymmetricKey) throws -> Data {
        let headerLength = magic.count + 1
        guard file.count > headerLength, file.prefix(magic.count) == magic, file[file.startIndex + magic.count] == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let header = file.prefix(headerLength)
        let box = try AES.GCM.SealedBox(combined: file.dropFirst(headerLength))
        return try AES.GCM.open(box, using: key, authenticating: header)
    }
}
