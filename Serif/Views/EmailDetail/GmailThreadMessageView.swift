import SwiftUI

/// Utility for HTML quote stripping and full-HTML computation.
/// View rendering has moved to ThreadMessageCardView.
enum GmailThreadMessageView {
    /// Compute the full HTML from message parts.
    static func computeFullHTML(message: GmailMessage, resolvedHTML: String?) -> String {
        if let resolved = resolvedHTML, !resolved.isEmpty { return resolved }
        if let html = message.htmlBody, !html.isEmpty { return html }
        if let plain = message.plainBody, !plain.isEmpty { return "<p>\(plain)</p>" }
        let body = message.body
        return body.isEmpty ? "" : "<p>\(body)</p>"
    }

    /// Removes quoted/replied content from HTML, returning (original, quoted?).
    /// Detects Gmail, Outlook, Apple Mail, and generic patterns.
    static func stripQuotedHTML(_ html: String) -> (original: String, quoted: String?) {
        // --- 1. Gmail: <div class="gmail_quote"> or <div class="gmail_quote_container"> ---
        if let range = html.range(of: #"<div\s+class\s*=\s*"[^"]*gmail_quote[^"]*""#,
                                  options: .regularExpression) {
            // Walk backwards to find the start of the containing element
            let before = String(html[html.startIndex..<range.lowerBound])
            let after = String(html[range.lowerBound...])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (before, after)
            }
        }

        // --- 2. Outlook: <div id="divRplyFwdMsg"> or <div id="appendonsend"> ---
        for pattern in [
            #"<div\s+id\s*=\s*"divRplyFwdMsg""#,
            #"<div\s+id\s*=\s*"appendonsend""#,
        ] {
            if let range = html.range(of: pattern, options: .regularExpression) {
                let before = String(html[html.startIndex..<range.lowerBound])
                let after = String(html[range.lowerBound...])
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (before, after)
                }
            }
        }

        // --- 2b. Outlook border-top separator: only if followed by "De"/"From" header ---
        if let range = html.range(of: #"<div\s+style\s*=\s*"[^"]*border-top\s*:\s*solid[^"]*"[^>]*>"#,
                                  options: .regularExpression) {
            // Check that "De" or "From" header appears shortly after the separator
            let afterStart = range.lowerBound
            let lookAhead = String(html[afterStart..<html.index(afterStart, offsetBy: min(500, html.distance(from: afterStart, to: html.endIndex)))])
            if lookAhead.range(of: #"(De|From)(\s|&nbsp;|;)*\s*:"#, options: .regularExpression) != nil {
                let before = String(html[html.startIndex..<range.lowerBound])
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (before, String(html[range.lowerBound...]))
                }
            }
        }

        // --- 3. "On ... wrote:" / "Le ... a écrit" in an <div class="gmail_attr"> or loose text ---
        let attrPatterns = [
            #"<div[^>]*class\s*=\s*"[^"]*gmail_attr[^"]*"[^>]*>.*?</div>\s*<blockquote"#,
            #"On\s.+wrote\s*:"#,
            #"Le\s.+a\s+(é|e)crit\s*:"#,
        ]
        for pattern in attrPatterns {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let before = String(html[html.startIndex..<range.lowerBound])
                let after = String(html[range.lowerBound...])
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (before, after)
                }
            }
        }

        // --- 4. Outlook FR/EN header block: "De :" / "From:" followed by "Envoyé"/"Sent" ---
        let headerPatterns = [
            #"<b>De(\s|&nbsp;)*:</\s*b>"#,
            #"<b>From(\s|&nbsp;)*:</\s*b>"#,
            #"-----\s*Original Message\s*-----"#,
            #"-----\s*Message d['']origine\s*-----"#,
            #"---------- Forwarded message ----------"#,
        ]
        for pattern in headerPatterns {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let before = String(html[html.startIndex..<range.lowerBound])
                let after = String(html[range.lowerBound...])
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (before, after)
                }
            }
        }

        // --- 5. Generic <blockquote> as last resort (only if it's a big trailing block) ---
        // Find the last <blockquote that takes up a significant portion of the HTML
        if let range = html.range(of: #"<blockquote[\s>]"#, options: [.regularExpression, .backwards]) {
            let before = String(html[html.startIndex..<range.lowerBound])
            let afterLen = html[range.lowerBound...].count
            // Only strip if the blockquote is at least 30% of the content
            if afterLen > html.count * 3 / 10 &&
               !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (before, String(html[range.lowerBound...]))
            }
        }

        return (html, nil)
    }
}
