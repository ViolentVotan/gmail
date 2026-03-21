import WebKit

/// Pre-warms WKWebViews with the email template shell loaded,
/// eliminating the WebContent process spawn delay on first use.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var available: [WKWebView] = []
    private init() {}

    /// Call once at app launch to pre-warm the pool.
    func warmUp() {
        guard available.isEmpty else { return }
        let webView = createWebView()
        webView.loadHTMLString(HTMLEmailView.templateHTML(), baseURL: nil)
        available.append(webView)
    }

    /// Returns a pre-warmed WKWebView, or creates one on demand.
    func dequeue() -> WKWebView {
        if let wv = available.popLast() {
            Task { @MainActor [weak self] in
                self?.replenish()
            }
            return wv
        }
        return createWebView()
    }

    /// Recycles a WKWebView back to the pool after use.
    func recycle(_ webView: WKWebView) {
        // Clear content for next use via JS (avoids full navigation cycle).
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "var el = document.getElementById('emailContent'); if (el) el.textContent = '';",
                arguments: [:],
                contentWorld: .page
            )
        }
        available.append(webView)
    }

    private func replenish() {
        guard available.isEmpty else { return }
        let wv = createWebView()
        wv.loadHTMLString(HTMLEmailView.templateHTML(), baseURL: nil)
        available.append(wv)
    }

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let disableTextExtraction = NSSelectorFromString("_setTextExtractionEnabled:")
        if config.preferences.responds(to: disableTextExtraction) {
            config.preferences.perform(disableTextExtraction, with: false as NSNumber)
        }
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let wv = PassthroughWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }
}
