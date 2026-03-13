import Foundation

extension String {
    // MARK: - Private static resources (compiled once)

    private static let hexEntityRegex     = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);")
    private static let decimalEntityRegex = try? NSRegularExpression(pattern: "&#([0-9]+);")

    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&ndash;": "\u{2013}", "&mdash;": "\u{2014}",
        "&hellip;": "\u{2026}", "&bull;": "\u{2022}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}",
        "&trade;": "\u{2122}",
        "&euro;": "\u{20AC}",
    ]

    /// Decodes all HTML entities (named, decimal &#123;, hex &#x1F;) to characters.
    /// Authoritative implementation — used by `strippingHTML` and `cleanedForAI`.
    func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        var result = self

        // Decode hex numeric HTML entities (&#x27; etc.)
        if let regex = Self.hexEntityRegex {
            let mutable = NSMutableString(string: result)
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                if let range = Range(match.range(at: 1), in: result),
                   let code = UInt32(result[range], radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    mutable.replaceCharacters(in: match.range, with: String(scalar))
                }
            }
            result = mutable as String
        }

        // Decode decimal numeric HTML entities (&#39; &#8203; etc.)
        if let regex = Self.decimalEntityRegex {
            let mutable = NSMutableString(string: result)
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                if let range = Range(match.range(at: 1), in: result),
                   let code = UInt32(result[range]),
                   let scalar = Unicode.Scalar(code) {
                    mutable.replaceCharacters(in: match.range, with: String(scalar))
                }
            }
            result = mutable as String
        }

        // Decode named HTML entities
        for (entity, replacement) in Self.namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode &amp; last to prevent double-decoding (e.g. &amp;lt; -> &lt; -> <)
        result = result.replacingOccurrences(of: "&amp;", with: "&")

        return result
    }

    private static let styleBlockRegex  = try? NSRegularExpression(pattern: "<style[^>]*>[\\s\\S]*?</style>",  options: [])
    private static let scriptBlockRegex = try? NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>", options: [])
    private static let brTagRegex       = try? NSRegularExpression(pattern: "<br\\s*/?>",  options: [])
    private static let openPTagRegex    = try? NSRegularExpression(pattern: "<p[^>]*>",    options: [])
    private static let openDivTagRegex  = try? NSRegularExpression(pattern: "<div[^>]*>",  options: [])
    private static let remainingTagsRegex = try? NSRegularExpression(pattern: "<[^>]+>",   options: [])
    private static let multipleNewlineRegex = try? NSRegularExpression(pattern: "\\n{3,}", options: [])

    var strippingHTML: String {
        var result = self
        let fullRange = { NSRange(result.startIndex..., in: result) }

        // Remove style/script blocks first
        if let re = Self.styleBlockRegex  { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "") }
        if let re = Self.scriptBlockRegex { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "") }
        // Replace block tags with newlines
        if let re = Self.brTagRegex      { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n") }
        if let re = Self.openPTagRegex   { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n") }
        result = result.replacingOccurrences(of: "</p>",    with: "")
        if let re = Self.openDivTagRegex { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n") }
        result = result.replacingOccurrences(of: "</div>",  with: "")
        // Strip remaining tags
        if let re = Self.remainingTagsRegex { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "") }
        // Decode HTML entities
        result = result.decodingHTMLEntities()
        // Collapse multiple blank lines
        if let re = Self.multipleNewlineRegex { result = re.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cleans email body text for AI consumption: strips HTML, decodes entities,
    /// removes quoted replies and signature noise, truncates to `maxLength`.
    ///
    /// Shared by QuickReplyService and SummaryService.
    /// SummaryService has been migrated to use this shared method.
    func cleanedForAI(maxLength: Int = 500) -> String {
        var text = self

        // Strip HTML tags
        if text.contains("<") {
            text = text.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
        }

        // Decode HTML entities
        text = text.decodingHTMLEntities()

        // Split into lines and filter noise
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix(">") { return false }
                let lower = line.lowercased()
                let noise = [
                    "sent from my iphone", "sent from my ipad",
                    "sent from outlook", "sent from mail",
                    "get outlook for", "unsubscribe",
                    "view this email in your browser",
                    "click here to unsubscribe",
                    "this email was sent to",
                    "if you no longer wish",
                    "-- ", "---", "___"
                ]
                return !noise.contains(where: { lower.hasPrefix($0) || lower == $0 })
            }

        let cleaned = lines.joined(separator: "\n")

        // Collapse excessive whitespace
        let collapsed = cleaned
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(collapsed.prefix(maxLength))
    }
}

// MARK: - Stable Hashing

/// DJB2 hash — deterministic, stable across runs. Used for avatar colors, label palettes, cache keys.
func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 5381
    for byte in string.utf8 {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return hash
}

// MARK: - Base64URL Decoding

extension Data {
    /// Decode a base64url-encoded string (RFC 4648 §5) to Data.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
