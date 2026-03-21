import Foundation

/// Strips HTML bloat before sending to WKWebView to reduce DOM parse time.
/// LinkedIn emails contain 30-40KB of HTML comments alone; stripping these
/// cuts DOM size by 30-50% and proportionally speeds up contrast fixing.
enum HTMLPreprocessor {

    /// Removes HTML comments, blocked tags, and collapses excessive whitespace.
    static func strip(_ html: String) -> String {
        var result = html
        result = removeHTMLComments(result)
        result = removeBlockedTags(result)
        result = collapseInterTagWhitespace(result)
        return result
    }

    // MARK: - Private

    /// Strip `<!-- ... -->` comments (often 30-40KB in marketing emails).
    private static func removeHTMLComments(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var i = html.startIndex
        let end = html.endIndex
        while i < end {
            // Check for comment start
            if html[i] == "<",
               html.index(i, offsetBy: 4, limitedBy: end) != nil,
               html[i...].hasPrefix("<!--") {
                // Find closing -->
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

    /// Strip `<script>`, `<iframe>`, `<form>`, `<object>`, `<embed>`, `<applet>` and their content.
    /// These are already blocked by CSP but removing them reduces DOM parse time.
    private static func removeBlockedTags(_ html: String) -> String {
        var result = html
        for tag in ["script", "iframe", "form", "object", "embed", "applet"] {
            result = removeTag(tag, from: result)
        }
        return result
    }

    private static func removeTag(_ tag: String, from html: String) -> String {
        var result = html
        while let openRange = result.range(of: "<\(tag)", options: .caseInsensitive) {
            // Look for closing tag
            if let closeRange = result.range(of: "</\(tag)>", options: .caseInsensitive, range: openRange.lowerBound..<result.endIndex) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else if let gtRange = result.range(of: ">", range: openRange.upperBound..<result.endIndex) {
                // Self-closing or unclosed — remove just the tag
                result.removeSubrange(openRange.lowerBound...gtRange.lowerBound)
            } else {
                break
            }
        }
        return result
    }

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
}
