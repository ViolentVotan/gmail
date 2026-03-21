import Foundation

/// Strips HTML bloat before sending to WKWebView to reduce DOM parse time.
/// LinkedIn emails contain 30-40KB of HTML comments alone; stripping these
/// cuts DOM size by 30-50% and proportionally speeds up contrast fixing.
enum HTMLPreprocessor {

    /// Removes HTML bloat in 9 ordered passes (outside-in).
    static func strip(_ html: String) -> String {
        var result = html
        result = removeHeadElement(result)
        result = removeHTMLComments(result)
        result = removeBlockedTags(result)
        result = removeStyleBlocks(result)
        result = removeHiddenElements(result)
        result = stripDataAttributes(result)
        result = stripMSOStyleProperties(result)
        result = shortenTrackingURLs(result)
        result = collapseInterTagWhitespace(result)
        return result
    }

    // MARK: - Pass 1: Head Element

    private static func removeHeadElement(_ html: String) -> String {
        removeTagWithContent("head", from: html)
    }

    // MARK: - Pass 2: HTML Comments

    /// Strip `<!-- ... -->` comments (often 30-40KB in marketing emails).
    /// Preserves `<!--[if !mso]>` non-MSO fallback content that WebKit should render.
    private static func removeHTMLComments(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var i = html.startIndex
        let end = html.endIndex
        while i < end {
            if html[i] == "<",
               html.index(i, offsetBy: 4, limitedBy: end) != nil,
               html[i...].hasPrefix("<!--") {
                // Check for <!--[if !mso]> — preserve inner content
                if html[i...].hasPrefix("<!--[if !mso]>") {
                    // Two forms:
                    // 1) <!--[if !mso]><!-- --><content><!--<![endif]-->
                    // 2) <!--[if !mso]><content><![endif]-->
                    let afterOpener = html.index(i, offsetBy: 14) // past "<!--[if !mso]>"
                    // Find the closing <![endif]-->
                    if let endifRange = html.range(of: "<![endif]-->", range: afterOpener..<end) {
                        var innerStart = afterOpener
                        var innerEnd = endifRange.lowerBound
                        // Strip optional leading <!-- --> (form 1)
                        let innerSlice = html[innerStart..<innerEnd]
                        if innerSlice.hasPrefix("<!-- -->") {
                            innerStart = html.index(innerStart, offsetBy: 8)
                        }
                        // Strip optional trailing <!--
                        let trimmed = html[innerStart..<innerEnd]
                        if trimmed.hasSuffix("<!--") {
                            innerEnd = html.index(innerEnd, offsetBy: -4)
                        }
                        result.append(contentsOf: html[innerStart..<innerEnd])
                        i = endifRange.upperBound
                        continue
                    }
                }
                // Regular comment or MSO conditional — strip entirely
                let searchStart = html.index(i, offsetBy: 4)
                if let closeRange = html.range(of: "-->", range: searchStart..<end) {
                    i = closeRange.upperBound
                    continue
                }
                // Unclosed comment — keep it to avoid breaking the HTML
                result.append(html[i])
                i = html.index(after: i)
            } else {
                result.append(html[i])
                i = html.index(after: i)
            }
        }
        return result
    }

    // MARK: - Pass 3: Blocked Tags

    /// Strip `<script>`, `<iframe>`, `<form>`, `<object>`, `<embed>`, `<applet>` and their content.
    private static func removeBlockedTags(_ html: String) -> String {
        var result = html
        for tag in ["script", "iframe", "form", "object", "embed", "applet"] {
            result = removeTagWithContent(tag, from: result)
        }
        return result
    }

    // MARK: - Pass 4: Style Blocks

    private static func removeStyleBlocks(_ html: String) -> String {
        removeTagWithContent("style", from: html)
    }

    // MARK: - Pass 5: Hidden Elements

    private static let hiddenPatterns: [NSRegularExpression] = {
        let patterns = [
            "display\\s*:\\s*none",
            "visibility\\s*:\\s*hidden",
            "mso-hide\\s*:\\s*all",
            "max-height\\s*:\\s*0(?:px)?",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let hiddenTagRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "<(\\w+)\\s[^>]*?style\\s*=\\s*\"([^\"]*)\"[^>]*>",
            options: .caseInsensitive
        )
    }()

    private static func removeHiddenElements(_ html: String) -> String {
        // Find opening tags with style attributes containing hidden patterns
        var result = html
        let nsString = result as NSString
        let matches = hiddenTagRegex.matches(in: result, range: NSRange(location: 0, length: nsString.length))

        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            let styleValue = nsString.substring(with: match.range(at: 2))
            let tagName = nsString.substring(with: match.range(at: 1)).lowercased()
            let styleRange = NSRange(location: 0, length: (styleValue as NSString).length)

            let isHidden = hiddenPatterns.contains { regex in
                regex.firstMatch(in: styleValue, range: styleRange) != nil
            }

            guard isHidden else { continue }

            // Find matching close tag
            let openTagEnd = match.range.location + match.range.length
            let closeTag = "</\(tagName)>"
            let searchRange = NSRange(location: openTagEnd, length: nsString.length - openTagEnd)
            let closeRange = nsString.range(of: closeTag, options: .caseInsensitive, range: searchRange)

            if closeRange.location != NSNotFound {
                let removeEnd = closeRange.location + closeRange.length
                let removeRange = NSRange(location: match.range.location, length: removeEnd - match.range.location)
                result = (result as NSString).replacingCharacters(in: removeRange, with: "")
            }
        }
        return result
    }

    // MARK: - Pass 6: data-* Attributes

    private static let dataTagRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "<[^>]+>", options: [])
    }()

    private static let dataAttrRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\s+data-[a-zA-Z0-9-]*\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|\\S+)",
            options: []
        )
    }()

    private static func stripDataAttributes(_ html: String) -> String {
        // Match data-* attributes within HTML tags only
        let nsString = html as NSString
        let tagMatches = dataTagRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        var result = html
        // Process in reverse to preserve ranges
        for tagMatch in tagMatches.reversed() {
            let tagString = nsString.substring(with: tagMatch.range)
            let cleaned = dataAttrRegex.stringByReplacingMatches(
                in: tagString,
                range: NSRange(location: 0, length: (tagString as NSString).length),
                withTemplate: ""
            )
            if cleaned != tagString {
                result = (result as NSString).replacingCharacters(in: tagMatch.range, with: cleaned)
            }
        }
        return result
    }

    // MARK: - Pass 7: MSO Style Properties

    private static let styleAttrRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\s*style\\s*=\\s*\"([^\"]*)\"",
            options: .caseInsensitive
        )
    }()

    private static let msoPropRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\s*;?\\s*mso-[^;:]+:[^;\"]*;?",
            options: .caseInsensitive
        )
    }()

    private static func stripMSOStyleProperties(_ html: String) -> String {
        let nsString = html as NSString
        let matches = styleAttrRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        var result = html
        for match in matches.reversed() {
            let styleValue = nsString.substring(with: match.range(at: 1))
            var cleaned = msoPropRegex.stringByReplacingMatches(
                in: styleValue,
                range: NSRange(location: 0, length: (styleValue as NSString).length),
                withTemplate: ""
            )
            // Clean up leading/trailing semicolons and whitespace
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            while cleaned.hasPrefix(";") {
                cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            while cleaned.hasSuffix(";") {
                cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
            }

            if cleaned.isEmpty {
                // Remove entire style attribute
                result = (result as NSString).replacingCharacters(in: match.range, with: "")
            } else if cleaned != styleValue {
                let replacement = " style=\"\(cleaned)\""
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Pass 8: Tracking URL Parameters

    private static let trackingParams: Set<String> = [
        "trackingId", "trkEmail", "trk", "midToken", "midSig",
        "otpToken", "eid", "lipi", "loid",
        "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
        "mc_eid", "mc_cid", "scp", "scid",
    ]

    private static let hrefRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "href\\s*=\\s*\"([^\"]*)\"",
            options: .caseInsensitive
        )
    }()

    private static func shortenTrackingURLs(_ html: String) -> String {
        let nsString = html as NSString
        let matches = hrefRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        var result = html
        for match in matches.reversed() {
            let urlString = nsString.substring(with: match.range(at: 1))
            guard urlString.contains("?") else { continue }
            guard var components = URLComponents(string: urlString) else { continue }
            guard let queryItems = components.queryItems, !queryItems.isEmpty else { continue }

            let filtered = queryItems.filter { !trackingParams.contains($0.name) }
            if filtered.count == queryItems.count { continue }

            components.queryItems = filtered.isEmpty ? nil : filtered
            guard let cleaned = components.string else { continue }
            let replacement = "href=\"\(cleaned)\""
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    // MARK: - Pass 9: Inter-tag Whitespace

    /// Collapse whitespace-only runs between `>` and `<` to a single space.
    /// Preserves whitespace inside text content.
    private static func collapseInterTagWhitespace(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var afterClose = false
        var wsRun = ""
        for ch in html {
            if ch == ">" {
                result.append(ch)
                afterClose = true
                wsRun = ""
                continue
            }
            if afterClose {
                if ch == "<" {
                    if !wsRun.isEmpty { result.append(" ") }
                    result.append(ch)
                    afterClose = false
                    wsRun = ""
                } else if ch.isWhitespace {
                    wsRun.append(ch)
                } else {
                    result.append(contentsOf: wsRun)
                    result.append(ch)
                    afterClose = false
                    wsRun = ""
                }
            } else {
                result.append(ch)
            }
        }
        result.append(contentsOf: wsRun)
        return result
    }

    // MARK: - Shared Helpers

    private static let tagContentRegexes: [String: (paired: NSRegularExpression, void: NSRegularExpression)] = {
        var cache: [String: (paired: NSRegularExpression, void: NSRegularExpression)] = [:]
        for tag in ["head", "script", "iframe", "form", "object", "embed", "applet", "style"] {
            cache[tag] = (
                paired: try! NSRegularExpression(
                    pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                    options: .caseInsensitive
                ),
                void: try! NSRegularExpression(
                    pattern: "<\(tag)\\b[^>]*/?>",
                    options: .caseInsensitive
                )
            )
        }
        return cache
    }()

    private static func removeTagWithContent(_ tag: String, from html: String) -> String {
        // Match <tag ...>...</tag> (with content) or <tag .../> or <tag ...> (void/self-closing)
        guard let regexes = tagContentRegexes[tag] else {
            // Fallback for tags not in the pre-compiled cache (shouldn't happen in practice)
            guard let pairedRegex = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                options: .caseInsensitive
            ),
            let voidRegex = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*/?>",
                options: .caseInsensitive
            ) else { return html }
            var result = pairedRegex.stringByReplacingMatches(
                in: html,
                range: NSRange(location: 0, length: (html as NSString).length),
                withTemplate: ""
            )
            result = voidRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
            return result
        }

        var result = regexes.paired.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: ""
        )
        result = regexes.void.stringByReplacingMatches(
            in: result,
            range: NSRange(location: 0, length: (result as NSString).length),
            withTemplate: ""
        )
        return result
    }
}
