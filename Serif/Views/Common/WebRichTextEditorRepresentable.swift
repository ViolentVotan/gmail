import SwiftUI
import WebKit

struct WebRichTextEditorRepresentable: NSViewRepresentable {
    @ObservedObject var state: WebRichTextEditorState
    @Binding var htmlContent: String
    @Environment(\.colorScheme) private var colorScheme
    var placeholder: String
    var autoFocus: Bool
    var onFileDrop: ((URL) -> Void)?
    var onOpenLink: ((URL) -> Void)?

    private func resolvedHex(_ nsColor: NSColor) -> String {
        nsColor.usingColorSpace(.sRGB).map {
            String(format: "#%02X%02X%02X",
                Int($0.redComponent * 255),
                Int($0.greenComponent * 255),
                Int($0.blueComponent * 255))
        } ?? "#000000"
    }

    func makeCoordinator() -> WebRichTextEditorCoordinator {
        WebRichTextEditorCoordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "editor")
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        let html = HTMLTemplate.editorHTML(
            textColor: resolvedHex(.textColor),
            backgroundColor: "transparent",
            accentColor: resolvedHex(.controlAccentColor),
            placeholderColor: resolvedHex(.tertiaryLabelColor),
            placeholderText: placeholder,
            initialHTML: htmlContent
        )
        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        // Update theme colors dynamically
        state.updateTheme(
            textColor: resolvedHex(.textColor),
            bgColor: "transparent",
            accentColor: resolvedHex(.controlAccentColor),
            placeholderColor: resolvedHex(.tertiaryLabelColor)
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebRichTextEditorCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
    }
}
