import Foundation

enum HTMLTemplate {

    static func editorHTML(
        textColor: String,
        backgroundColor: String,
        accentColor: String,
        placeholderColor: String,
        placeholderText: String,
        fontSize: Int = 13,
        initialHTML: String = ""
    ) -> String {
        let jsSource: String
        if let url = Bundle.main.url(forResource: "editor", withExtension: "js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            jsSource = js
        } else {
            jsSource = "// editor.js not found"
        }

        let nonce = UUID().uuidString

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; frame-src 'none';">
        <style>
        :root {
            --text-color: \(sanitizeCSSValue(textColor));
            --bg-color: \(sanitizeCSSValue(backgroundColor));
            --accent-color: \(sanitizeCSSValue(accentColor));
            --placeholder-color: \(sanitizeCSSValue(placeholderColor));
        }
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            background: var(--bg-color);
            color: var(--text-color);
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;
            font-size: \(fontSize)px;
            line-height: 1.5;
            -webkit-font-smoothing: antialiased;
        }
        #editor {
            min-height: 100%;
            outline: none;
            padding: 8px 4px;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        #editor {
            position: relative;
        }
        #editor:empty::before {
            content: attr(data-placeholder);
            color: var(--placeholder-color);
            pointer-events: none;
            position: absolute;
        }
        #editor a {
            color: var(--accent-color);
            cursor: pointer;
            text-decoration: underline;
            text-decoration-color: var(--accent-color);
            text-underline-offset: 2px;
        }
        #editor a:hover {
            text-decoration-thickness: 2px;
        }
        #link-popover input:focus {
            border-color: var(--accent-color) !important;
            outline: none;
        }
        #link-popover button:hover {
            opacity: 0.85;
        }
        #editor blockquote {
            border-left: 3px solid var(--placeholder-color);
            margin: 8px 0;
            padding: 4px 12px;
            color: var(--placeholder-color);
        }
        #editor pre, #editor code {
            font-family: 'SF Mono', Menlo, monospace;
            font-size: 12px;
            background: rgba(128, 128, 128, 0.1);
            padding: 2px 4px;
            border-radius: 3px;
        }
        #editor img {
            max-width: 100%;
            height: auto;
        }
        #editor .vik-signature {
            color: var(--placeholder-color);
        }
        </style>
        </head>
        <body>
        <div id="editor" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Email body" tabindex="0" data-placeholder="\(placeholderText.replacingOccurrences(of: "\"", with: "&quot;"))">\(Self.sanitizeHTML(initialHTML))</div>
        <div id="a11y-status" aria-live="polite" aria-atomic="true" style="position:absolute;clip:rect(0 0 0 0);width:1px;height:1px;overflow:hidden;"></div>
        <script nonce="\(nonce)">
        \(jsSource)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - CSS Sanitization

    /// Strips all characters outside a safe set to prevent CSS injection via color parameters.
    private static func sanitizeCSSValue(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#%,.() "))
        return String(value.unicodeScalars.filter { allowed.contains($0) })
    }

    // MARK: - HTML Sanitization (pre-compiled regexes)

    private static let scriptTagRegex      = try! NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>",   options: .caseInsensitive)
    private static let styleTagRegex       = try! NSRegularExpression(pattern: "<style[^>]*>[\\s\\S]*?</style>",    options: .caseInsensitive)
    private static let iframeTagRegex      = try! NSRegularExpression(pattern: "<iframe[^>]*>[\\s\\S]*?</iframe>",  options: .caseInsensitive)
    private static let iframeSelfRegex     = try! NSRegularExpression(pattern: "<iframe[^>]*/>",                    options: .caseInsensitive)
    private static let objectTagRegex      = try! NSRegularExpression(pattern: "<object[^>]*>[\\s\\S]*?</object>",  options: .caseInsensitive)
    private static let embedTagRegex       = try! NSRegularExpression(pattern: "<embed[^>]*>",                      options: .caseInsensitive)
    private static let formTagRegex        = try! NSRegularExpression(pattern: "<form[^>]*>[\\s\\S]*?</form>",      options: .caseInsensitive)
    private static let linkTagRegex        = try! NSRegularExpression(pattern: "<link[^>]*>",                       options: .caseInsensitive)
    private static let baseTagRegex        = try! NSRegularExpression(pattern: "<base[^>]*>",                       options: .caseInsensitive)
    private static let metaRefreshRegex    = try! NSRegularExpression(pattern: "<meta[^>]*http-equiv[^>]*>",        options: .caseInsensitive)
    private static let javascriptURLRegex  = try! NSRegularExpression(pattern: "javascript\\s*:",                   options: .caseInsensitive)
    private static let vbscriptURLRegex    = try! NSRegularExpression(pattern: "vbscript\\s*:",                     options: .caseInsensitive)
    private static let dataTextHTMLRegex   = try! NSRegularExpression(pattern: "data\\s*:\\s*text/html",            options: .caseInsensitive)
    private static let onEventQuotedRegex  = try! NSRegularExpression(pattern: "\\bon\\w+\\s*=\\s*([\"'])[\\s\\S]*?\\1", options: .caseInsensitive)
    private static let onEventUnquotedRegex = try! NSRegularExpression(pattern: "\\bon\\w+\\s*=\\s*[^\\s>]+",      options: .caseInsensitive)

    /// Strips dangerous HTML constructs from email content before embedding in the editor.
    private static func sanitizeHTML(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        var result = html
        let range = { NSRange(result.startIndex..., in: result) }

        result = scriptTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = styleTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = iframeTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = iframeSelfRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = objectTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = embedTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = formTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = linkTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = baseTagRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = metaRefreshRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = javascriptURLRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "blocked:")
        result = vbscriptURLRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "blocked:")
        result = dataTextHTMLRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "blocked:")
        // Remove event handler attributes (on*=); quoted variant first, then unquoted
        result = onEventQuotedRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        result = onEventUnquotedRegex.stringByReplacingMatches(in: result, range: range(), withTemplate: "")
        return result
    }
}
