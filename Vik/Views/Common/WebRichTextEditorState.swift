import AppKit
import WebKit

@Observable @MainActor final class WebRichTextEditorState {
    // Formatting state (updated by JS selectionChanged)
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    var alignment: NSTextAlignment = .left
    var selectedText: String = ""
    var isBlockquote = false
    var highlightColor: NSColor? = nil
    var fontFamily: String = ""
    var linkPopoverRequest: (text: String, url: String)?
    var translationRequested = false

    // WKWebView reference (set by Coordinator)
    weak var webView: WKWebView?

    // Inline images pending send
    var pendingInlineImages: [InlineImageAttachment] = []

    // MARK: - Formatting

    func toggleBold()          { evalJS("execBold()") }
    func toggleItalic()        { evalJS("execItalic()") }
    func toggleUnderline()     { evalJS("execUnderline()") }
    func toggleStrikethrough() { evalJS("execStrikethrough()") }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        evalJS("execFontSize(\(Int(size)))")
    }

    func setTextColor(_ color: NSColor) {
        textColor = color
        let hex = colorToHex(color)
        evalJS("execForeColor('\(hex)')")
    }

    func removeFormat() { evalJS("execRemoveFormat()") }

    func setAlignment(_ alignment: NSTextAlignment) {
        self.alignment = alignment
        let dir: String
        switch alignment {
        case .center:    dir = "center"
        case .right:     dir = "right"
        case .justified: dir = "justify"
        default:         dir = "left"
        }
        evalJS("execAlign('\(dir)')")
    }

    func insertNumberedList()  { evalJS("execInsertOrderedList()") }
    func insertBulletList()    { evalJS("execInsertUnorderedList()") }
    func increaseIndent()      { evalJS("execIndent()") }
    func decreaseIndent()      { evalJS("execOutdent()") }
    // Note: evalJS() calls WKWebView.evaluateJavaScript() on our own sandboxed
    // editor JS — not arbitrary code execution.
    func toggleBlockquote()    { evalJS("execToggleBlockquote()") }

    func setHighlightColor(_ color: NSColor) {
        highlightColor = color
        let hex = colorToHex(color)
        evalJS("execHighlightColor('\(hex)')")
    }

    func removeHighlightColor() {
        highlightColor = nil
        evalJS("execRemoveHighlight()")
    }

    func setFontFamily(_ family: String) {
        fontFamily = family
        let escaped = family.replacingOccurrences(of: "'", with: "\\'")
        evalJS("execFontFamily('\(escaped)')")
    }

    func insertLink(url: String, text: String? = nil) {
        let escapedURL = url.replacingOccurrences(of: "'", with: "\\'")
        if let text = text {
            let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
            evalJS("execInsertLink('\(escapedURL)', '\(escapedText)')")
        } else {
            evalJS("execInsertLink('\(escapedURL)', null)")
        }
    }

    func removeLink() { evalJS("execUnlink()") }

    func undo() { webView?.evaluateJavaScript("performUndo()", completionHandler: nil) }
    func redo() { webView?.evaluateJavaScript("performRedo()", completionHandler: nil) }

    // MARK: - Content

    func setHTML(_ html: String) {
        let escaped = html.jsEscaped
        evalJS("setHTML(\(escaped))")
    }

    func insertHTML(_ html: String) {
        let escaped = html.jsEscaped
        evalJS("insertHTML(\(escaped))")
    }

    @MainActor func getHTMLAsync() async -> String {
        guard let webView else { return "" }
        do {
            let result = try await webView.evaluateJavaScript("getHTML()")
            return result as? String ?? ""
        } catch {
            return ""
        }
    }

    func focus() { evalJS("focusEditor()") }

    // MARK: - Images

    func insertImage(from url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url) else { return }

            // Compress if wider than 480px — done off MainActor
            let imageData: Data
            let mimeType: String
            if let image = NSImage(data: data) {
                let maxWidth: CGFloat = 480
                if image.size.width > maxWidth {
                    let ratio = maxWidth / image.size.width
                    let newSize = NSSize(width: maxWidth, height: image.size.height * ratio)
                    let resized = NSImage(size: newSize, flipped: false) { rect in
                        image.draw(in: rect)
                        return true
                    }
                    if let tiff = resized.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        imageData = jpeg
                        mimeType = "image/jpeg"
                    } else {
                        imageData = data
                        mimeType = self.detectMimeType(data)
                    }
                } else {
                    imageData = data
                    mimeType = self.detectMimeType(data)
                }
            } else {
                imageData = data
                mimeType = self.detectMimeType(data)
            }

            await self.commitInsertedImage(data: imageData, mimeType: mimeType)
        }
    }

    @MainActor
    private func commitInsertedImage(data imageData: Data, mimeType: String) {
        let cid = "img_\(UUID().uuidString.prefix(8))"
        let ext = mimeType == "image/png" ? "png" : "jpg"
        let filename = "\(cid).\(ext)"

        pendingInlineImages.append(InlineImageAttachment(
            contentID: cid, data: imageData, mimeType: mimeType, filename: filename
        ))

        let base64 = imageData.base64EncodedString()
        let dataURL = "data:\(mimeType);base64,\(base64)"
        evalJS("insertImageBase64('\(dataURL)', '\(cid)')")
    }

    // MARK: - Theme update

    func updateTheme(textColor: String, bgColor: String, accentColor: String, placeholderColor: String) {
        evalJS("setThemeColors('\(textColor)', '\(bgColor)', '\(accentColor)', '\(placeholderColor)')")
    }

    // MARK: - Selection state update (called by Coordinator)

    func handleSelectionChanged(_ info: [String: Any]) {
        let newBold = info["bold"] as? Bool ?? false
        let newItalic = info["italic"] as? Bool ?? false
        let newUnderline = info["underline"] as? Bool ?? false
        let newStrikethrough = info["strikethrough"] as? Bool ?? false
        let newSelectedText = info["selectedText"] as? String ?? ""
        let newFontSize = (info["fontSize"] as? Int).map { CGFloat($0) }
        let newTextColor = (info["textColor"] as? String).flatMap { nsColorFromHex($0) }
        var newAlignment: NSTextAlignment?
        if let align = info["alignment"] as? String {
            switch align {
            case "center":  newAlignment = .center
            case "right":   newAlignment = .right
            case "justify": newAlignment = .justified
            default:        newAlignment = .left
            }
        }

        isBold = newBold
        isItalic = newItalic
        isUnderline = newUnderline
        isStrikethrough = newStrikethrough
        selectedText = newSelectedText
        if let fs = newFontSize { fontSize = fs }
        if let tc = newTextColor { textColor = tc }
        if let a = newAlignment { alignment = a }

        isBlockquote = info["isBlockquote"] as? Bool ?? false

        highlightColor = (info["backgroundColor"] as? String)
            .flatMap { $0.isEmpty ? nil : nsColorFromHex($0) }

        fontFamily = info["fontFamily"] as? String ?? ""
    }

    // MARK: - Private

    /// Executes a predefined JS function in the sandboxed editor WKWebView.
    /// Fire-and-forget; errors are discarded (editor state is always recoverable).
    func evalJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func colorToHex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func nsColorFromHex(_ hex: String) -> NSColor {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    nonisolated private func detectMimeType(_ data: Data) -> String {
        guard data.count >= 4 else { return "image/png" }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0x89 && bytes[1] == 0x50 { return "image/png" }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes[0] == 0x47 && bytes[1] == 0x49 { return "image/gif" }
        return "image/png"
    }
}

// MARK: - String JS escaping

extension String {
    var jsEscaped: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "'\(escaped)'"
    }
}
