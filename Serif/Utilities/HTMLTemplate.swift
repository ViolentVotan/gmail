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
            --text-color: \(textColor);
            --bg-color: \(backgroundColor);
            --accent-color: \(accentColor);
            --placeholder-color: \(placeholderColor);
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
        #editor .serif-signature {
            color: var(--placeholder-color);
        }
        </style>
        </head>
        <body>
        <div id="editor" contenteditable="true" data-placeholder="\(placeholderText.replacingOccurrences(of: "\"", with: "&quot;"))">\(Self.sanitizeHTML(initialHTML))</div>
        <script nonce="\(nonce)">
        \(jsSource)
        </script>
        </body>
        </html>
        """
    }

    // MARK: - HTML Sanitization

    /// Strips dangerous HTML constructs from email content before embedding in the editor.
    private static func sanitizeHTML(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        var result = html
        // Remove <script> tags and their content
        result = result.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <iframe> tags
        result = result.replacingOccurrences(
            of: "<iframe[^>]*>[\\s\\S]*?</iframe>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "<iframe[^>]*/>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <object> tags and their content
        result = result.replacingOccurrences(
            of: "<object[^>]*>[\\s\\S]*?</object>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <embed> tags (self-closing)
        result = result.replacingOccurrences(
            of: "<embed[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <form> tags and their content
        result = result.replacingOccurrences(
            of: "<form[^>]*>[\\s\\S]*?</form>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <base> tags (can hijack relative URLs)
        result = result.replacingOccurrences(
            of: "<base[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove <meta http-equiv="refresh"> tags (can redirect)
        result = result.replacingOccurrences(
            of: "<meta[^>]*http-equiv[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove javascript: URLs from attributes
        result = result.replacingOccurrences(
            of: "javascript\\s*:",
            with: "blocked:",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove data:text/html URIs which can execute scripts
        result = result.replacingOccurrences(
            of: "data\\s*:\\s*text/html",
            with: "blocked:",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove event handler attributes (on*=)
        // Use [\\s\\S]*? instead of .*? so newlines inside quoted values are matched.
        result = result.replacingOccurrences(
            of: "\\bon\\w+\\s*=\\s*([\"'])[\\s\\S]*?\\1",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "\\bon\\w+\\s*=\\s*[^\\s>]+",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }
}
