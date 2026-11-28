import Darwin
import Foundation

/// An IPv4 or IPv6 address, as copied: alone, with a prefix length (10.0.0.0/8) or with a
/// port (10.0.0.1:8080, [::1]:443). IPv6 link-local addresses may name an interface (fe80::1%en0).
struct IPAddress: Equatable, Sendable {
    enum Version: String, Sendable { case v4 = "IPv4", v6 = "IPv6" }

    /// Where the address can be reached. Private, loopback and link-local addresses stay inside
    /// a network; public addresses are on the internet.
    enum Scope: String, Sendable {
        case `public` = "Public"
        case `private` = "Private"
        case loopback = "Loopback"
        case linkLocal = "Link-local"
        case multicast = "Multicast"
        case unspecified = "Unspecified"
    }

    let version: Version
    /// 4 or 16 bytes, in network order.
    let bytes: [UInt8]

    /// One address. Nil when any part of the text is not.
    init?(_ text: String) {
        var host = Substring(text)
        // [IPv6]:port
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let rest = host[host.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), Self.isPort(rest.dropFirst()) else { return nil }
            }
            host = host[host.index(after: host.startIndex)..<close]
            guard host.contains(":"), let bytes = Self.parse6(host) else { return nil }
            self.init(version: .v6, bytes: bytes)
            return
        }
        // /prefix length
        var prefix: Substring?
        if let slash = host.firstIndex(of: "/") {
            prefix = host[host.index(after: slash)...]
            host = host[..<slash]
        }
        if host.contains(":"), !host.contains(".") || host.filter({ $0 == ":" }).count > 1 {
            guard let bytes = Self.parse6(host) else { return nil }
            if let prefix { guard Self.isNumber(prefix, upTo: 128) else { return nil } }
            self.init(version: .v6, bytes: bytes)
            return
        }
        // IPv4, maybe with :port
        if let colon = host.firstIndex(of: ":") {
            guard prefix == nil, Self.isPort(host[host.index(after: colon)...]) else { return nil }
            host = host[..<colon]
        }
        guard let bytes = Self.parse4(host) else { return nil }
        if let prefix { guard Self.isNumber(prefix, upTo: 32) else { return nil } }
        self.init(version: .v4, bytes: bytes)
    }

    private init(version: Version, bytes: [UInt8]) {
        self.version = version
        self.bytes = bytes
    }

    var scope: Scope {
        let b = bytes
        if version == .v4 {
            switch (b[0], b[1]) {
            case (0, _) where b.allSatisfy { $0 == 0 }: return .unspecified
            case (127, _): return .loopback
            case (10, _), (172, 16...31), (192, 168), (100, 64...127): return .private
            case (169, 254): return .linkLocal
            case (224...239, _): return .multicast
            default: return .public
            }
        }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return .loopback }
        // ::ffff:a.b.c.d is an IPv4 address.
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
            return IPAddress(version: .v4, bytes: Array(b[12...])).scope
        }
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return .linkLocal }
        if b[0] & 0xFE == 0xFC { return .private }
        if b[0] == 0xFF { return .multicast }
        return .public
    }

    /// Four decimal numbers 0–255, without leading zeros ("01" is not an address part).
    private static func parse4(_ text: Substring) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func parse6(_ text: Substring) -> [UInt8]? {
        var address = text
        if let percent = address.firstIndex(of: "%") {
            let zone = address[address.index(after: percent)...]
            guard !zone.isEmpty, zone.count <= 16, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            address = address[..<percent]
        }
        guard address.count <= 45, address.contains(where: \.isHexDigit) else { return nil }
        var result = in6_addr()
        guard inet_pton(AF_INET6, String(address), &result) == 1 else { return nil }
        return withUnsafeBytes(of: result) { Array($0) }
    }

    private static func isPort(_ text: Substring) -> Bool { isNumber(text, upTo: 65535, from: 1) }

    private static func isNumber(_ text: Substring, upTo max: Int, from min: Int = 0) -> Bool {
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text) else { return false }
        return (min...max).contains(value)
    }
}

extension ContentDetector {
    /// One address, or a list separated by commas, semicolons, spaces or new lines.
    static func ipAddresses(in text: String) -> [IPAddress]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 5_000,
              trimmed.contains(where: { $0 == "." || $0 == ":" }) else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard (1...100).contains(parts.count) else { return nil }
        var addresses: [IPAddress] = []
        for part in parts {
            guard let address = IPAddress(String(part)) else { return nil }
            addresses.append(address)
        }
        return addresses
    }
}
