import Foundation

/// Finds secrets in copied text: API keys and tokens, private keys, payment cards and IBANs.
///
/// Rules that keep false positives low:
/// - Tokens with a fixed prefix (sk-, ghp_, AKIA …) count anywhere in a short text, so a line such
///   as `OPENAI_API_KEY=sk-…` is caught.
/// - Card numbers and IBANs count only when the whole copied text is the number, and only when
///   the checksum (Luhn, ISO 7064 mod 97) is valid.
/// - Private key blocks count in a text of any length.
enum SensitiveDetector {
    struct Finding: Equatable, Sendable {
        /// What was found, for example "GitHub token".
        let reason: String
        /// A display form that does not reveal the secret, for example "ghp_…f00D".
        let masked: String
    }

    /// Prefix tokens are searched for in texts up to this length.
    static let tokenSearchLimit = 2_000

    private static let tokens: [(reason: String, pattern: String, keep: Int)] = [
        ("Anthropic API key", #"sk-ant-[A-Za-z0-9_\-]{20,}"#, 7),
        ("Stripe key", #"(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}"#, 8),
        ("OpenAI API key", #"sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#, 3),
        ("GitHub token", #"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"#, 4),
        ("AWS access key", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#, 4),
        ("Slack token", #"xox[abprs]-[A-Za-z0-9\-]{10,}"#, 5),
        ("Google API key", #"AIza[0-9A-Za-z_\-]{35}"#, 4),
        ("JSON Web Token", #"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, 3),
    ]
    private static let compiled: [(reason: String, regex: NSRegularExpression, keep: Int)] = tokens.map {
        ($0.reason, try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_\\-])" + $0.pattern), $0.keep)
    }
    private static let privateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN (?:(RSA|EC|DSA|OPENSSH|ENCRYPTED|PGP) )?PRIVATE KEY(?: BLOCK)?-----"#
    )

    static func detect(_ text: String) -> Finding? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = privateKey.firstMatch(in: text, range: range) {
            let type = Range(match.range(at: 1), in: text).map { String(text[$0]) + " " } ?? ""
            return Finding(reason: "Private key", masked: "-----BEGIN \(type)PRIVATE KEY----- ••••")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= tokenSearchLimit {
            let trimmedRange = NSRange(trimmed.startIndex..., in: trimmed)
            for token in compiled {
                if let match = token.regex.firstMatch(in: trimmed, range: trimmedRange),
                   let found = Range(match.range, in: trimmed) {
                    return Finding(reason: token.reason, masked: mask(String(trimmed[found]), keepPrefix: token.keep))
                }
            }
        }
        if let card = paymentCard(trimmed) { return card }
        if let iban = iban(trimmed) { return iban }
        return nil
    }

    /// "ghp_" + "…" + the last 4 characters.
    static func mask(_ token: String, keepPrefix: Int) -> String {
        String(token.prefix(keepPrefix)) + "…" + String(token.suffix(4))
    }

    // MARK: - Payment cards

    static func paymentCard(_ text: String) -> Finding? {
        guard text.count <= 23, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == " " || $0 == "-") }) else { return nil }
        let digits = text.filter(\.isNumber)
        guard (13...19).contains(digits.count), knownCardPrefix(digits), luhn(digits) else { return nil }
        return Finding(reason: "Payment card", masked: "•••• " + digits.suffix(4))
    }

    /// Visa, Mastercard, American Express, Discover, JCB, Diners, UnionPay and Troy.
    private static func knownCardPrefix(_ digits: String) -> Bool {
        let two = Int(digits.prefix(2)) ?? 0
        let four = Int(digits.prefix(4)) ?? 0
        return digits.hasPrefix("4")
            || (51...55).contains(two) || (2221...2720).contains(four)
            || two == 34 || two == 37
            || digits.hasPrefix("6011") || digits.hasPrefix("65") || digits.hasPrefix("62")
            || two == 35 || two == 36 || two == 38
            || digits.hasPrefix("9792")
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    // MARK: - IBAN

    static func iban(_ text: String) -> Finding? {
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()
        guard (15...34).contains(compact.count),
              compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              compact.prefix(2).allSatisfy(\.isLetter),
              compact.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return nil }
        // ISO 13616: move the first four characters to the end, letters become 10…35, mod 97 == 1.
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let value: Int
            if let digit = character.wholeNumberValue {
                value = digit
            } else if let ascii = character.asciiValue {
                value = Int(ascii) - 55
            } else {
                return nil
            }
            remainder = (remainder * (value >= 10 ? 100 : 10) + value) % 97
        }
        guard remainder == 1 else { return nil }
        return Finding(reason: "IBAN", masked: String(compact.prefix(2)) + "•• •••• " + compact.suffix(4))
    }
}
