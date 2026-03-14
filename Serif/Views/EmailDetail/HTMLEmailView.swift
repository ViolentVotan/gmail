@preconcurrency import WebKit
import SwiftUI

// NOTE: Native SwiftUI WebView (macOS 26) cannot replace WKWebView here because
// HTMLEmailView requires capabilities not exposed by the native API:
//   1. User scripts — dark mode color-fixing JS that walks the DOM
//   2. Script message handlers — image-load notifications for re-measurement
//   3. evaluateJavaScript — content height measurement for sizing the frame
//   4. WKNavigationDelegate — link interception with custom onOpenLink callback
//
// WebRichTextEditorRepresentable and InAppBrowserView also remain WKWebView
// for similar reasons (JS evaluation, script message handlers).

// MARK: - PassthroughWebView

/// Forwards scroll events to the parent responder so the SwiftUI
/// ScrollView (not the WebView) handles vertical scrolling.
private final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// Prevent this read-only WebView from showing a text cursor,
    /// which causes flickering when overlapping with the reply editor.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

// MARK: - HTMLEmailView

struct HTMLEmailView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    var onOpenLink: ((URL) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightChanged")
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let textHex = NSColor.textColor.usingColorSpace(.sRGB).map {
            String(format: "#%02X%02X%02X",
                Int($0.redComponent * 255),
                Int($0.greenComponent * 255),
                Int($0.blueComponent * 255))
        } ?? "#FFFFFF"
        let cacheKey = "\(html)|\(colorScheme)"
        guard context.coordinator.lastCacheKey != cacheKey else { return }
        context.coordinator.lastCacheKey = cacheKey
        context.coordinator.isLoadingContent = true
        // Defer height reset so SwiftUI processes it after the current render pass.
        // This shrinks the frame before didFinish measures the new content.
        Task { @MainActor in
            self.contentHeight = 1
        }

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let userScript = WKUserScript(
            source: Self.userScriptSource(textHex: textHex),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)

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
            font-size: \(Int(NSFont.systemFont(ofSize: 0).pointSize))px;
            line-height: 1.65;
            color: \(textHex);
            background-color: transparent;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        img { max-width: 100% !important; height: auto !important; }
        a { color: #1a73e8; }
        blockquote { border-left: 3px solid #dadce0; margin: 8px 0; padding: 4px 12px; color: #5f6368; }
        pre, code { font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px; background: rgba(0,0,0,0.06); padding: 2px 4px; border-radius: 3px; }
        table { border-collapse: collapse; }
        * { box-sizing: border-box; max-width: 100% !important; cursor: default !important; }

        @media (prefers-color-scheme: dark) {
            a { color: #8ab4f8; }
            blockquote { border-left-color: #5f6368; color: #9aa0a6; }
            pre, code { background: rgba(255,255,255,0.1); color: #e8eaed; }
        }
        </style>
        </head>
        <body><div id="emailContent" style="padding-bottom:16px">\(html)</div></body>
        </html>
        """
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged")
    }

    // MARK: - User Script

    /// JavaScript injected at document-end to fix dark mode colors and observe image loads.
    ///
    /// Posts `heightChanged` messages to the native side instead of requiring periodic
    /// `evaluateJavaScript` polling. A `ResizeObserver` on `#emailContent` fires whenever
    /// the content box changes (e.g., after an image loads and expands the layout).
    private static func userScriptSource(textHex: String) -> String {
        """
        var THEME_TEXT = '\(textHex)';

        function fixDarkModeColors() {
            if (!window.matchMedia('(prefers-color-scheme: dark)').matches) return;

            var BG_LUM = 0.015;
            var MIN_CR = 4.0;

            function linearize(c) {
                c /= 255;
                return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
            }
            function relativeLum(r, g, b) {
                return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
            }
            function contrastWith(lum) {
                var hi = Math.max(lum, BG_LUM), lo = Math.min(lum, BG_LUM);
                return (hi + 0.05) / (lo + 0.05);
            }
            function parseRgb(s) {
                var i = s.indexOf('(');
                if (i < 0) return null;
                var parts = s.slice(i + 1).split(',');
                return parts.length >= 3 ? [parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2])] : null;
            }
            function hue2rgb(p, q, t) {
                if (t < 0) t += 1;
                if (t > 1) t -= 1;
                if (t < 1/6) return p + (q - p) * 6 * t;
                if (t < 0.5) return q;
                if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
                return p;
            }
            function lightenToContrast(r, g, b) {
                r /= 255; g /= 255; b /= 255;
                var mx = Math.max(r, g, b), mn = Math.min(r, g, b);
                var h = 0, s = 0, l = (mx + mn) / 2;
                if (mx !== mn) {
                    var d = mx - mn;
                    s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
                    if      (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
                    else if (mx === g) h = (b - r) / d + 2;
                    else               h = (r - g) / d + 4;
                    h /= 6;
                }
                for (var tl = Math.max(l + 0.1, 0.55); tl <= 1.0; tl += 0.04) {
                    var q2 = tl < 0.5 ? tl * (1 + s) : tl + s - tl * s;
                    var p2 = 2 * tl - q2;
                    var nr = Math.round(hue2rgb(p2, q2, h + 1/3) * 255);
                    var ng = Math.round(hue2rgb(p2, q2, h)       * 255);
                    var nb = Math.round(hue2rgb(p2, q2, h - 1/3) * 255);
                    if (contrastWith(relativeLum(nr, ng, nb)) >= MIN_CR)
                        return 'rgb(' + nr + ',' + ng + ',' + nb + ')';
                }
                return THEME_TEXT;
            }

            function isAchromatic(r, g, b) {
                var mx = Math.max(r, g, b), mn = Math.min(r, g, b);
                return (mx - mn) < 30 && mx < 80;
            }

            function effectiveBgLum(el) {
                var node = el;
                while (node && node !== document.documentElement) {
                    var bg = window.getComputedStyle(node).backgroundColor;
                    var rgba = parseRgb(bg);
                    if (rgba) {
                        var parts = bg.slice(bg.indexOf('(') + 1).split(',');
                        var alpha = parts.length >= 4 ? parseFloat(parts[3]) : 1;
                        if (alpha > 0.1) return relativeLum(rgba[0], rgba[1], rgba[2]);
                    }
                    node = node.parentElement;
                }
                return BG_LUM;
            }

            function processEl(el) {
                var c = window.getComputedStyle(el).color;
                var rgb = parseRgb(c);
                if (!rgb) return;
                var bgLum = effectiveBgLum(el);
                if (bgLum > 0.4) return;
                var textLum = relativeLum(rgb[0], rgb[1], rgb[2]);
                var hi = Math.max(textLum, bgLum), lo = Math.min(textLum, bgLum);
                var cr = (hi + 0.05) / (lo + 0.05);
                if (cr >= MIN_CR) return;
                var replacement = isAchromatic(rgb[0], rgb[1], rgb[2])
                    ? THEME_TEXT
                    : lightenToContrast(rgb[0], rgb[1], rgb[2]);
                el.style.setProperty('color', replacement, 'important');
            }

            document.querySelectorAll(
                'body,p,div,span,td,th,li,a,font,b,strong,em,i,h1,h2,h3,h4,h5,h6,small,label,cite,blockquote'
            ).forEach(processEl);
        }

        fixDarkModeColors();

        // Observe content size changes via ResizeObserver — fires when images load,
        // fonts render, or any layout shift occurs. Replaces the old approach of
        // periodic evaluateJavaScript polling + image-load event listeners.
        var content = document.getElementById('emailContent');
        if (content) {
            var lastH = 0;
            new ResizeObserver(function(entries) {
                var h = Math.ceil(entries[0].contentRect.height);
                if (h > 0 && h !== lastH) {
                    lastH = h;
                    window.webkit.messageHandlers.heightChanged.postMessage(h);
                }
            }).observe(content);
            // Send initial height
            var initH = content.offsetHeight;
            if (initH > 0) {
                window.webkit.messageHandlers.heightChanged.postMessage(initH);
            }
        }
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLEmailView
        var lastCacheKey = ""
        var isLoadingContent = false
        weak var webView: WKWebView?

        init(_ parent: HTMLEmailView) { self.parent = parent }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "heightChanged",
                  let height = message.body as? CGFloat,
                  height > 0
            else { return }
            Task { @MainActor [weak self] in
                self?.parent.contentHeight = height
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoadingContent = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Open clicked links externally (or via the provided callback)
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if let onOpenLink = parent.onOpenLink {
                    onOpenLink(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }

            // Only allow the initial HTML load (about:blank from loadHTMLString)
            guard isLoadingContent,
                  navigationAction.navigationType == .other,
                  navigationAction.request.url?.scheme == "about"
                      || navigationAction.request.url?.absoluteString == "about:blank"
            else {
                return .cancel
            }
            return .allow
        }
    }
}
