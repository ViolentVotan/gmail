import Foundation

/// Strips HTML bloat before sending to WKWebView to reduce DOM parse time.
/// LinkedIn emails contain 30-40KB of HTML comments alone; stripping these
/// cuts DOM size by 30-50% and proportionally speeds up contrast fixing.
enum HTMLPreprocessor {

    /// Removes HTML bloat in 8 ordered passes (outside-in).
    /// `<style>` blocks are preserved — email CSS is needed for proper layout.
    /// CSP (`style-src 'unsafe-inline'`) allows them; `script-src 'none'` blocks JS.
    static func strip(_ html: String) -> String {
        var result = html
        result = removeHeadElement(result)
        result = removeHTMLComments(result)
        result = removeBlockedTags(result)
        result = removeHiddenElements(result)
        result = stripDataAttributes(result)
        result = stripMSOStyleProperties(result)
        result = shortenTrackingURLs(result)
        result = collapseInterTagWhitespace(result)
        return result
    }

    // MARK: - Pass 1: Head Element (preserving style blocks)

    /// Removes `<head>` but extracts and preserves `<style>` blocks within it.
    /// Other head content (meta, link, title, script refs) is discarded.
    private static func removeHeadElement(_ html: String) -> String {
        guard let headRegexes = tagContentRegexes["head"],
              let styleRegexes = tagContentRegexes["style"]
        else {
            return removeTagWithContent("head", from: html)
        }

        let nsString = html as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        guard let headMatch = headRegexes.paired.firstMatch(in: html, range: fullRange) else {
            return headRegexes.void.stringByReplacingMatches(in: html, range: fullRange, withTemplate: "")
        }

        let headContent = nsString.substring(with: headMatch.range)
        let headNS = headContent as NSString
        let headRange = NSRange(location: 0, length: headNS.length)
        let styleMatches = styleRegexes.paired.matches(in: headContent, range: headRange)

        let preservedStyles = styleMatches.isEmpty
            ? ""
            : styleMatches.map { headNS.substring(with: $0.range) }.joined(separator: "\n")

        return nsString.replacingCharacters(in: headMatch.range, with: preservedStyles)
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

    // MARK: - Pass 4: Hidden Elements

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
        // Find opening tags with style attributes containing hidden patterns.
        // Use NSMutableString and process in reverse so earlier ranges stay valid
        // after removing later ranges (all ranges are computed from the same string).
        let nsString = html as NSString
        let matches = hiddenTagRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        var rangesToRemove: [NSRange] = []
        for match in matches {
            let styleValue = nsString.substring(with: match.range(at: 2))
            let tagName = nsString.substring(with: match.range(at: 1)).lowercased()
            let styleRange = NSRange(location: 0, length: (styleValue as NSString).length)

            let isHidden = hiddenPatterns.contains { regex in
                regex.firstMatch(in: styleValue, range: styleRange) != nil
            }

            guard isHidden else { continue }

            let openTagEnd = match.range.location + match.range.length
            let closeTag = "</\(tagName)>"
            let searchRange = NSRange(location: openTagEnd, length: nsString.length - openTagEnd)
            let closeRange = nsString.range(of: closeTag, options: .caseInsensitive, range: searchRange)

            if closeRange.location != NSNotFound {
                let removeEnd = closeRange.location + closeRange.length
                rangesToRemove.append(NSRange(location: match.range.location, length: removeEnd - match.range.location))
            }
        }

        guard !rangesToRemove.isEmpty else { return html }

        // Merge overlapping/nested ranges (e.g. hidden div inside another hidden div).
        // Ranges are already sorted by location (regex matches left-to-right).
        var merged: [NSRange] = []
        for range in rangesToRemove {
            if let last = merged.last {
                let lastEnd = last.location + last.length
                let rangeEnd = range.location + range.length
                if range.location < lastEnd {
                    // Overlapping or nested — extend the previous range if needed
                    let newEnd = max(lastEnd, rangeEnd)
                    merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
                    continue
                }
            }
            merged.append(range)
        }

        // Apply removals in reverse order so earlier ranges stay valid
        let mutable = NSMutableString(string: html)
        for range in merged.reversed() {
            mutable.replaceCharacters(in: range, with: "")
        }
        return mutable as String
    }

    // MARK: - Pass 5: data-* Attributes

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
        let nsString = html as NSString
        let tagMatches = dataTagRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        let mutable = NSMutableString(string: html)
        for tagMatch in tagMatches.reversed() {
            let tagString = nsString.substring(with: tagMatch.range)
            let cleaned = dataAttrRegex.stringByReplacingMatches(
                in: tagString,
                range: NSRange(location: 0, length: (tagString as NSString).length),
                withTemplate: ""
            )
            if cleaned != tagString {
                mutable.replaceCharacters(in: tagMatch.range, with: cleaned)
            }
        }
        return mutable as String
    }

    // MARK: - Pass 6: MSO Style Properties

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

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let styleValue = nsString.substring(with: match.range(at: 1))
            var cleaned = msoPropRegex.stringByReplacingMatches(
                in: styleValue,
                range: NSRange(location: 0, length: (styleValue as NSString).length),
                withTemplate: ""
            )
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            while cleaned.hasPrefix(";") {
                cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            while cleaned.hasSuffix(";") {
                cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
            }

            if cleaned.isEmpty {
                mutable.replaceCharacters(in: match.range, with: "")
            } else if cleaned != styleValue {
                let replacement = " style=\"\(cleaned)\""
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }

    // MARK: - Pass 7: Tracking URL Parameters

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

        let mutable = NSMutableString(string: html)
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
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    // MARK: - Pass 8: Inter-tag Whitespace

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
