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
        for _ in 0..<3 {
            let webView = createWebView()
            webView.loadHTMLString(HTMLEmailView.templateHTML(), baseURL: nil)
            available.append(webView)
        }
    }

    /// Returns a pre-warmed WKWebView, or creates one on demand.
    /// Returned views always have the template loaded (or loading).
    func dequeue() -> WKWebView {
        if let wv = available.popLast() {
            Task { @MainActor [weak self] in
                self?.replenish()
            }
            return wv
        }
        // Fallback: create on demand and start loading the template.
        // didFinish will fire once the template is ready.
        let wv = createWebView()
        wv.loadHTMLString(HTMLEmailView.templateHTML(), baseURL: nil)
        return wv
    }

    /// Recycles a WKWebView back to the pool after use.
    func recycle(_ webView: WKWebView) {
        // Clear content before returning to pool — append only after JS completes
        // so a fast dequeue() never gets a view still showing old content.
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "var el = document.getElementById('emailContent'); if (el) el.textContent = '';",
                arguments: [:],
                contentWorld: .page
            )
            guard available.count < 3 else { return }
            available.append(webView)
        }
    }

    private func replenish() {
        let deficit = 3 - available.count
        guard deficit > 0 else { return }
        for _ in 0..<deficit {
            let wv = createWebView()
            wv.loadHTMLString(HTMLEmailView.templateHTML(), baseURL: nil)
            available.append(wv)
        }
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
