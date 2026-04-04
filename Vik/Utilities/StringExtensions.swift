import Foundation

extension String {
    // MARK: - Private static resources (compiled once)

    private static let hexEntityRegex     = try! NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);")
    private static let decimalEntityRegex = try! NSRegularExpression(pattern: "&#([0-9]+);")

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
        let hexMutable = NSMutableString(string: result)
        for match in Self.hexEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            if let range = Range(match.range(at: 1), in: result),
               let code = UInt32(result[range], radix: 16),
               let scalar = Unicode.Scalar(code) {
                hexMutable.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        result = hexMutable as String

        // Decode decimal numeric HTML entities (&#39; &#8203; etc.)
        let decMutable = NSMutableString(string: result)
        for match in Self.decimalEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            if let range = Range(match.range(at: 1), in: result),
               let code = UInt32(result[range]),
               let scalar = Unicode.Scalar(code) {
                decMutable.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        result = decMutable as String

        // Decode named HTML entities
        for (entity, replacement) in Self.namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode &amp; last to prevent double-decoding (e.g. &amp;lt; -> &lt; -> <)
        result = result.replacingOccurrences(of: "&amp;", with: "&")

        return result
    }

    private static let styleBlockRegex  = try! NSRegularExpression(pattern: "<style[^>]*>[\\s\\S]*?</style>",  options: [])
    private static let scriptBlockRegex = try! NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>", options: [])
    private static let brTagRegex       = try! NSRegularExpression(pattern: "<br\\s*/?>",  options: [])
    private static let openPTagRegex    = try! NSRegularExpression(pattern: "<p[^>]*>",    options: [])
    private static let openDivTagRegex  = try! NSRegularExpression(pattern: "<div[^>]*>",  options: [])
    private static let remainingTagsRegex = try! NSRegularExpression(pattern: "<[^>]+>",   options: [])
    private static let multipleNewlineRegex = try! NSRegularExpression(pattern: "\\n{3,}", options: [])

    /// HTML-escapes `&`, `<`, `>`, `"`, and `'` to prevent XSS when interpolating into HTML.
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var strippingHTML: String {
        var result = self
        let fullRange = { NSRange(result.startIndex..., in: result) }

        // Remove style/script blocks first
        result = Self.styleBlockRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "")
        result = Self.scriptBlockRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "")
        // Replace block tags with newlines
        result = Self.brTagRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n")
        result = Self.openPTagRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n")
        result = result.replacingOccurrences(of: "</p>",    with: "")
        result = Self.openDivTagRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n")
        result = result.replacingOccurrences(of: "</div>",  with: "")
        // Strip remaining tags
        result = Self.remainingTagsRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "")
        // Decode HTML entities
        result = result.decodingHTMLEntities()
        // Collapse multiple blank lines
        result = Self.multipleNewlineRegex.stringByReplacingMatches(in: result, range: fullRange(), withTemplate: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Pre-compiled regexes for cleanedForAI
    private static let htmlTagRegexAI     = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let multipleSpaceRegex = try! NSRegularExpression(pattern: " {2,}")

    /// Cleans email body text for AI consumption: strips HTML, decodes entities,
    /// removes quoted replies and signature noise, truncates to `maxLength`.
    ///
    /// Shared by SummaryService and LabelSuggestionService.
    func cleanedForAI(maxLength: Int = 500) -> String {
        var text = self

        // Strip HTML tags
        if text.contains("<") {
            text = Self.htmlTagRegexAI.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
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

        var cleaned = lines.joined(separator: "\n")

        // Collapse excessive whitespace using pre-compiled regexes
        cleaned = Self.multipleNewlineRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "\n\n")
        cleaned = Self.multipleSpaceRegex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return String(cleaned.prefix(maxLength))
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

// MARK: - Base64URL

extension Data {
    /// Decode a base64url-encoded string (RFC 4648 §5) to Data.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }

    /// Encode Data to a base64url string (RFC 4648 §5) — no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Email Subject Prefixes

extension String {
    /// Ensures the string has a "Re: " prefix for replies, adding it if absent.
    /// Case-insensitive to handle Outlook variants ("RE: ", "re: ", etc.).
    var withReplyPrefix: String {
        if lowercased().hasPrefix("re:") { return self }
        return "Re: \(self)"
    }

    /// Ensures the string has a "Fwd: " prefix for forwards, adding it if absent.
    /// Case-insensitive to handle variants ("FWD: ", "fw: ", etc.).
    var withForwardPrefix: String {
        let l = lowercased()
        if l.hasPrefix("fwd:") || l.hasPrefix("fw:") { return self }
        return "Fwd: \(self)"
    }

    /// Returns `nil` if the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
