import AppKit
import CommonCrypto
import CryptoKit
import Foundation

/// Reads Raycast's "Export Settings & Data" file (.rayconfig) with its clipboard history.
///
/// The format is not documented. What is known (community notes, checked on a real export
/// on 26 Nov 2026): the file is AES-256-CBC encrypted the way `openssl enc -aes-256-cbc
/// -nosalt -md sha256 -k <password>` does it; the plain bytes are a 16-byte header, then
/// gzip, then JSON. Clipboard entries are in
/// `builtin_package_clipboardHistory.clipboardHistoryRecords`: category (text, link, file,
/// image), text, richText (Base64 RTF), filePath, createdAt, modifiedAt (ISO 8601),
/// copyCount, applicationPath. Images stay in Raycast's cache folder, outside the export,
/// so they cannot be imported.
enum RaycastImport {
    enum Failure: Error {
        case wrongPassword
        case noClipboardHistory
    }

    /// OpenSSL's EVP_BytesToKey with SHA-256, one round and no salt: key = SHA256(password),
    /// IV = the first 16 bytes of SHA256(key + password).
    static func keyAndIV(password: String) -> (key: Data, iv: Data) {
        let secret = Data(password.utf8)
        let first = Data(SHA256.hash(data: secret))
        let second = Data(SHA256.hash(data: first + secret))
        return (first, second.prefix(16))
    }

    /// The JSON inside the file. A wrong password fails here (bad padding or no gzip data).
    /// A password with letters such as "ç" can be stored composed or decomposed (Unicode NFC
    /// or NFD), depending on the app it was typed in: both forms are tried.
    static func decrypt(_ file: Data, password: String) throws -> Data {
        var tried = Set<Data>()
        for form in [password, password.precomposedStringWithCanonicalMapping, password.decomposedStringWithCanonicalMapping]
        where tried.insert(Data(form.utf8)).inserted {
            if let json = try? decrypt(file, exactPassword: form) { return json }
        }
        throw Failure.wrongPassword
    }

    private static func decrypt(_ file: Data, exactPassword password: String) throws -> Data {
        let (key, iv) = keyAndIV(password: password)
        var output = Data(count: file.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            file.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, file.count, out.baseAddress, outputCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess, written > 16 else { throw Failure.wrongPassword }
        let gzip = output.prefix(written).dropFirst(16)
        guard let json = gunzip(Data(gzip)) else { throw Failure.wrongPassword }
        return json
    }

    /// The deflate data inside a gzip member (RFC 1952), inflated.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 } // FNAME
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 } // FCOMMENT
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index < bytes.count - 8 else { return nil }
        // Apple's "zlib" algorithm is raw deflate, which is what gzip wraps.
        return try? (Data(bytes[index..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }

    /// The clipboard records as Trove export items, and how many images had to be left out.
    static func items(fromJSON json: Data) throws -> (items: [Transfer.Item], skippedImages: Int) {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let history = root["builtin_package_clipboardHistory"] as? [String: Any],
              let records = history["clipboardHistoryRecords"] as? [[String: Any]] else { throw Failure.noClipboardHistory }
        let dates = ISO8601DateFormatter()
        var items: [Transfer.Item] = []
        var skippedImages = 0
        var apps: [String: (name: String?, bundleID: String?)] = [:]
        for record in records {
            let category = record["category"] as? String ?? "text"
            let first = (record["createdAt"] as? String).flatMap(dates.date(from:)) ?? Date()
            let last = (record["modifiedAt"] as? String).flatMap(dates.date(from:)) ?? first
            var item = Transfer.Item(kind: ClipKind.text.rawValue, pinned: false, timesCopied: max(1, record["copyCount"] as? Int ?? 1),
                                     firstCopiedAt: min(first, last), lastCopiedAt: max(first, last))
            if let path = record["applicationPath"] as? String, !path.isEmpty {
                let app = apps[path] ?? source(path)
                apps[path] = app
                item.sourceApp = app.name
                item.sourceBundleID = app.bundleID
            }
            switch category {
            case "image":
                skippedImages += 1
                continue
            case "file":
                guard let path = record["filePath"] as? String ?? record["text"] as? String, !path.isEmpty else { continue }
                item.kind = ClipKind.file.rawValue
                item.files = [path]
            default:
                guard let text = record["text"] as? String, !text.isEmpty else { continue }
                item.text = text
                item.rtf = (record["richText"] as? String).flatMap { Data(base64Encoded: $0) }
            }
            items.append(item)
        }
        return (items, skippedImages)
    }

    /// "/Applications/Arc.app" → Arc and its bundle identifier (when the app is still there);
    /// "com.apple.Safari" → that identifier.
    private static func source(_ path: String) -> (name: String?, bundleID: String?) {
        if path.hasSuffix(".app") {
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (name, Bundle(path: path)?.bundleIdentifier)
        }
        if path.contains("."), !path.contains("/") {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: path)
                .map { $0.deletingPathExtension().lastPathComponent }
            return (name ?? path.components(separatedBy: ".").last, path)
        }
        return (nil, nil)
    }
}
