import CommonCrypto
import CryptoKit
import Foundation

/// The key file ("clipboard.key") next to the database.
///
/// It holds no secret by itself: the store ID (to find the key in this Mac's Keychain) and,
/// when the user sets a recovery password, a copy of the data key encrypted with a key derived
/// from that password. With the recovery password, the history opens on another Mac.
struct KeyFile: Codable, Equatable, Sendable {
    struct Recovery: Codable, Equatable, Sendable {
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        /// AES-256-GCM sealed data key (nonce, ciphertext, tag). The store ID is authenticated data.
        var sealedKey: Data
    }

    var format = "com.iokoda.clipboard.key"
    var version = 1
    var storeID: UUID
    var createdAt: Date
    var recovery: Recovery?

    static let fileName = "clipboard.key"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func read(in directory: URL) throws -> KeyFile? {
        let url = url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(KeyFile.self, from: Data(contentsOf: url))
        guard file.format == "com.iokoda.clipboard.key", file.version == 1 else {
            throw VaultError.unsupportedKeyFile
        }
        return file
    }

    func write(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}

enum VaultError: LocalizedError, Equatable {
    case wrongPassword
    case passwordTooShort
    case noRecoveryPassword
    case unsupportedKeyFile

    var errorDescription: String? {
        switch self {
        case .wrongPassword: L("The recovery password is not correct.")
        case .passwordTooShort:
            String(localized: "Use at least \(Vault.minimumPasswordLength.formatted()) characters.")
        case .noRecoveryPassword: L("This history has no recovery password.")
        case .unsupportedKeyFile: L("The key file was made by a newer version of Trove.")
        }
    }
}

/// Decides how a history folder opens and manages its keys.
struct Vault: Sendable {
    enum State: Sendable {
        /// The key is available. The store can open.
        case ready(DataKey)
        /// The history is encrypted, this Mac has no key, and a recovery password can unlock it.
        case locked(KeyFile)
        /// The history is encrypted and no key can be found.
        case unrecoverable
    }

    static let minimumPasswordLength = 8
    /// OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
    static let defaultIterations = 600_000

    let keyStore: KeyStore
    var iterations = Vault.defaultIterations

    /// Finds the key for a folder, or creates one for a new or unencrypted history.
    /// A new key is saved to the Keychain before the key file is written.
    func prepare(directory: URL) throws -> State {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encryptedData = Store.hasEncryptedData(in: directory)

        if let file = try KeyFile.read(in: directory) {
            if let raw = try keyStore.load(storeID: file.storeID), raw.count == DataKey.byteCount {
                return .ready(DataKey(raw: raw))
            }
            if file.recovery != nil { return .locked(file) }
            guard !encryptedData else { return .unrecoverable }
            // Nothing is encrypted yet (an interrupted first start). A new key is safe.
            let key = DataKey.random()
            try keyStore.save(key.raw, storeID: file.storeID)
            return .ready(key)
        }

        guard !encryptedData else { return .unrecoverable }
        let key = DataKey.random()
        let file = KeyFile(storeID: UUID(), createdAt: Date())
        try keyStore.save(key.raw, storeID: file.storeID)
        try file.write(in: directory)
        return .ready(key)
    }

    /// Opens the data key with the recovery password and saves it to this Mac's Keychain.
    func unlock(_ file: KeyFile, password: String) throws -> DataKey {
        guard let recovery = file.recovery else { throw VaultError.noRecoveryPassword }
        let wrapping = try Self.deriveKey(password: password, salt: recovery.salt, iterations: recovery.iterations)
        let raw: Data
        do {
            let box = try AES.GCM.SealedBox(combined: recovery.sealedKey)
            raw = try AES.GCM.open(box, using: wrapping, authenticating: Data(file.storeID.uuidString.utf8))
        } catch {
            throw VaultError.wrongPassword
        }
        guard raw.count == DataKey.byteCount else { throw VaultError.wrongPassword }
        try keyStore.save(raw, storeID: file.storeID)
        return DataKey(raw: raw)
    }

    func hasRecoveryPassword(directory: URL) -> Bool {
        (try? KeyFile.read(in: directory))?.recovery != nil
    }

    /// Sets, changes or (with nil) removes the recovery password of a folder.
    func setRecoveryPassword(_ password: String?, key: DataKey, directory: URL) throws {
        guard var file = try KeyFile.read(in: directory) else { throw CocoaError(.fileNoSuchFile) }
        if let password {
            guard password.count >= Self.minimumPasswordLength else { throw VaultError.passwordTooShort }
            let salt = Self.randomBytes(16)
            let wrapping = try Self.deriveKey(password: password, salt: salt, iterations: iterations)
            let box = try AES.GCM.seal(key.raw, using: wrapping, authenticating: Data(file.storeID.uuidString.utf8))
            guard let sealed = box.combined else { throw CocoaError(.coderInvalidValue) }
            file.recovery = KeyFile.Recovery(iterations: iterations, salt: salt, sealedKey: sealed)
        } else {
            file.recovery = nil
        }
        try file.write(in: directory)
    }

    // MARK: - Primitives

    /// Rounds accepted from a key file or an export: a damaged or hostile value must neither
    /// crash (UInt32 conversion) nor hang the app for minutes.
    static let acceptedIterations = 1_000...10_000_000

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard acceptedIterations.contains(iterations) else { throw VaultError.unsupportedKeyFile }
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: Int8.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordChars.baseAddress, passwordChars.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &derived, derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        defer { derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "The system random generator failed")
        return bytes
    }
}
