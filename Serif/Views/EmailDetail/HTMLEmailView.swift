import WebKit
import SwiftUI

// Forwards all scroll events to the parent responder so the SwiftUI
// ScrollView (not the WebView) handles vertical scrolling.
private class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct HTMLEmailView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "imageLog")
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let fullHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <meta name='color-scheme' content='light dark'>
        <style>
        html, body {
            margin: 0;
            padding: 0;
            overflow: hidden;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.65;
            color: #202124;
            background-color: #ffffff;
            padding-bottom: 16px;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        img { max-width: 100% !important; height: auto !important; }
        a { color: #1a73e8; }
        blockquote { border-left: 3px solid #dadce0; margin: 8px 0; padding: 4px 12px; color: #5f6368; }
        pre, code { font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px; background: rgba(0,0,0,0.06); padding: 2px 4px; border-radius: 3px; }
        table { border-collapse: collapse; }
        * { box-sizing: border-box; max-width: 100% !important; }

        @media (prefers-color-scheme: dark) {
            body {
                color: #e8eaed;
                background-color: transparent;
            }
            a { color: #8ab4f8; }
            blockquote { border-left-color: #5f6368; color: #9aa0a6; }
            pre, code { background: rgba(255,255,255,0.1); color: #e8eaed; }
        }
        </style>
        <script>
        window.addEventListener('load', function() {
            var imgs = document.querySelectorAll('img');
            var loaded = 0, failed = 0;
            imgs.forEach(function(img) {
                window.webkit.messageHandlers.imageLog.postMessage(
                    'img src=' + img.src.substring(0,80) + ' complete=' + img.complete + ' naturalW=' + img.naturalWidth
                );
                if (!img.complete) {
                    img.addEventListener('load', function() {
                        loaded++;
                        window.webkit.messageHandlers.imageLog.postMessage('LOADED: ' + this.src.substring(0,80));
                        window.webkit.messageHandlers.imageLog.postMessage('REMEASURE');
                    });
                    img.addEventListener('error', function() {
                        failed++;
                        window.webkit.messageHandlers.imageLog.postMessage('FAILED: ' + this.src.substring(0,80));
                    });
                }
            });
            window.webkit.messageHandlers.imageLog.postMessage('Total imgs: ' + imgs.length + ', already complete: ' + Array.from(imgs).filter(i=>i.complete).length);
        });
        </script>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: URL(string: "https://mail.google.com/"))
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLEmailView
        var lastHTML: String = ""

        init(_ parent: HTMLEmailView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            if body == "REMEASURE" {
                DispatchQueue.main.async { [weak self] in
                    // Re-measure when any image finishes loading
                    self?.remeasureIfNeeded()
                }
            } else {
                print("[HTMLEmailView] \(body)")
            }
        }

        private func remeasureIfNeeded() {
            // Will be called with the webView on next cycle
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureHeight(webView)
            // Re-measure after delays to catch lazy/slow images
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let webView else { return }
                    self?.measureHeight(webView)
                }
            }
        }

        private func measureHeight(_ webView: WKWebView) {
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, document.body.offsetHeight)"
            ) { [weak self] result, _ in
                DispatchQueue.main.async {
                    if let h = result as? CGFloat, h > 0 {
                        self?.parent.contentHeight = h
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
