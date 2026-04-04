import WebKit
import SwiftUI

// NOTE: Native SwiftUI WebView (macOS 26) cannot replace WKWebView here because
// HTMLEmailView requires capabilities not exposed by the native API:
//   1. User scripts — dark mode color-fixing JS that walks the DOM
//   2. Script message handlers — image-load notifications for re-measurement
//   3. evaluateJavaScript — content height measurement for sizing the frame
//   4. WKNavigationDelegate — link interception with custom onOpenLink callback
//
// WebRichTextEditorRepresentable also remains WKWebView for similar reasons
// (JS evaluation, script message handlers). InAppBrowserView has been migrated
// to native SwiftUI WebView + WebPage (macOS 26).

// MARK: - PassthroughWebView

/// Forwards scroll events to the parent responder so the SwiftUI
/// ScrollView (not the WebView) handles vertical scrolling.
final class PassthroughWebView: WKWebView {
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
    @Binding var isContentLoaded: Bool
    var allowRemoteImages: Bool = false
    var onOpenLink: ((URL) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    // Note: WKProcessPool was deprecated in macOS 12 — all web views
    // automatically share a single WebContent process now.

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Template HTML

    /// Static HTML shell loaded once per WKWebView lifetime. Uses CSS custom
    /// properties (`--text-color`) so color scheme changes update via JS
    /// instead of triggering a full `loadHTMLString` navigation cycle.
    ///
    /// When `allowRemoteImages` is false (default), remote images are blocked via
    /// CSP so novel trackers cannot load even if they bypass `TrackerBlockerService`.
    /// Passing `true` relaxes the policy to permit HTTPS image sources.
    static func templateHTML(allowRemoteImages: Bool = false) -> String {
        let imgSrc = allowRemoteImages ? "data: cid: https:" : "data: cid:"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <meta name='color-scheme' content='light dark'>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imgSrc); style-src 'unsafe-inline'; font-src https:; frame-src 'none'; connect-src 'none'; script-src 'none';">
        <style>
        :root {
            --text-color: #FFFFFF;
        }
        html, body {
            margin: 0;
            padding: 0;
            overflow: hidden;
            background-color: transparent !important;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
            font-size: \(Int(NSFont.systemFont(ofSize: 0).pointSize))px;
            line-height: 1.65;
            color: var(--text-color);
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        img { max-width: 100% !important; height: auto !important; }
        a { color: #1a73e8; }
        a:hover { text-decoration-thickness: 1.5px; }
        blockquote { border-left: 3px solid #dadce0; margin: 8px 0; padding: 4px 12px; color: #5f6368; }
        pre, code { font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px; background: rgba(0,0,0,0.06); padding: 2px 4px; border-radius: 3px; }
        hr { border: none; border-top: 1px solid rgba(128,128,128,0.3); margin: 16px 0; }
        table { border-collapse: collapse; }
        ::selection { background: rgba(58,111,240,0.25); }
        * { box-sizing: border-box; max-width: 100% !important; cursor: default !important; }

        @media (prefers-color-scheme: dark) {
            a { color: #8ab4f8; }
            blockquote { border-left-color: #5f6368; color: #9aa0a6; }
            pre, code { background: rgba(255,255,255,0.1); color: #e8eaed; }
            hr { border-top-color: rgba(255,255,255,0.15); }
            ::selection { background: rgba(100,160,255,0.3); }
            /* CSS-first dark mode: fix common hard-coded light-mode colors
               without JS DOM walking. Handles ~80% of email dark mode issues. */
            [style*="color: #000"], [style*="color:#000"],
            [style*="color: black"], [style*="color:black"],
            [style*="color: rgb(0, 0, 0)"], [style*="color:rgb(0,0,0)"],
            [style*="color:#333"], [style*="color: #333"],
            [style*="color:#222"], [style*="color: #222"] {
                color: var(--text-color) !important;
            }
            [style*="background-color: #fff"], [style*="background-color:#fff"],
            [style*="background-color: white"], [style*="background-color:white"],
            [style*="background: #fff"], [style*="background:#fff"],
            [style*="background-color: #FFF"], [style*="background-color:#FFF"],
            [style*="background: white"], [style*="background:white"],
            [style*="background-color: #ffffff"], [style*="background-color:#ffffff"],
            [style*="background-color: #FFFFFF"], [style*="background-color:#FFFFFF"] {
                background-color: transparent !important;
            }
        }
        @media (prefers-color-scheme: light) {
            a { color: #1a73e8; }
            blockquote { border-left: 3px solid #dadce0; color: #5f6368; }
            pre, code { background: rgba(0,0,0,0.06); color: inherit; }
            /* CSS-first light mode: fix white/near-white text that's invisible
               on light backgrounds (e.g. LinkedIn dark-themed email sections). */
            [style*="color: #fff"], [style*="color:#fff"],
            [style*="color: #FFF"], [style*="color:#FFF"],
            [style*="color: white"], [style*="color:white"],
            [style*="color: #ffffff"], [style*="color:#ffffff"],
            [style*="color: #FFFFFF"], [style*="color:#FFFFFF"],
            [style*="color: rgb(255, 255, 255)"], [style*="color:rgb(255,255,255)"],
            [style*="color:#fafafa"], [style*="color: #fafafa"],
            [style*="color:#FAFAFA"], [style*="color: #FAFAFA"],
            [style*="color:#f5f5f5"], [style*="color: #f5f5f5"],
            [style*="color:#eee"], [style*="color: #eee"],
            [style*="color:#EEE"], [style*="color: #EEE"],
            [style*="color:#eeeeee"], [style*="color: #eeeeee"],
            [style*="color:#EEEEEE"], [style*="color: #EEEEEE"] {
                color: var(--text-color) !important;
            }
        }
        </style>
        </head>
        <body><div id="emailContent" style="padding-bottom:16px"></div></body>
        </html>
        """
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> WKWebView {
        // Dequeue a pre-warmed web view from the pool (template already loaded),
        // or get a fresh one if the pool is empty.
        let webView = WebViewPool.shared.dequeue()

        // Add coordinator-specific handlers (pool creates bare web views without these).
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(context.coordinator), name: "heightChanged"
        )
        let bgLum = colorScheme == .dark ? "0.015" : "0.96"
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.userScriptSource(bgLum: bgLum),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastColorScheme = colorScheme
        context.coordinator.pendingCSSUpdate = (
            textHex: Self.currentTextHex(), bgLum: bgLum
        )

        // If pool provided a pre-loaded template, it's already ready.
        // The user script (added via addUserScript) only runs on navigation,
        // so we must manually execute it for pre-loaded views to define
        // fixContrastColorsAsync, reportHeight, ResizeObserver, etc.
        if !webView.isLoading {
            context.coordinator.templateReady = true
            let scriptSource = Self.userScriptSource(bgLum: bgLum)
            Task { @MainActor in
                _ = try? await webView.evaluateJavaScript(scriptSource)
            }
        }
        // Otherwise didFinish will fire, user script runs automatically via atDocumentEnd.

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Handle allowRemoteImages changes — requires a full template reload to
        // apply the new CSP (CSP meta tags cannot be relaxed after navigation).
        if coordinator.lastAllowRemoteImages != allowRemoteImages {
            coordinator.lastAllowRemoteImages = allowRemoteImages
            coordinator.templateReady = false
            coordinator.pendingHTML = html
            coordinator.lastContentKey = html
            coordinator.parent.isContentLoaded = false
            let bgLum = colorScheme == .dark ? "0.015" : "0.96"
            coordinator.pendingCSSUpdate = (textHex: Self.currentTextHex(), bgLum: bgLum)
            webView.loadHTMLString(Self.templateHTML(allowRemoteImages: allowRemoteImages), baseURL: nil)
            return
        }

        // Handle color scheme changes -- update CSS vars + re-run contrast fix.
        if coordinator.lastColorScheme != colorScheme {
            coordinator.lastColorScheme = colorScheme
            let textHex = Self.currentTextHex()
            let bgLum = colorScheme == .dark ? "0.015" : "0.96"
            if coordinator.templateReady {
                coordinator.updateColorScheme(textHex: textHex, bgLum: bgLum)
            } else {
                coordinator.pendingCSSUpdate = (textHex: textHex, bgLum: bgLum)
            }
        }

        // Handle content changes -- inject via JS (no loadHTMLString).
        guard coordinator.lastContentKey != html else { return }
        coordinator.lastContentKey = html
        coordinator.parent.isContentLoaded = false

        if coordinator.templateReady {
            coordinator.injectContent(html)
        } else {
            coordinator.pendingHTML = html
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.templateReady = false
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "heightChanged")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        WebViewPool.shared.recycle(webView)
    }

    // MARK: - Helpers

    private static func currentTextHex() -> String {
        NSColor.textColor.usingColorSpace(.sRGB).map {
            String(format: "#%02X%02X%02X",
                Int($0.redComponent * 255),
                Int($0.greenComponent * 255),
                Int($0.blueComponent * 255))
        } ?? "#FFFFFF"
    }

    // MARK: - User Script

    /// JavaScript injected at document-end to fix contrast and observe content height.
    ///
    /// `fixContrastColorsAsync()` uses a `TreeWalker` to lazily iterate elements
    /// in chunks of 60 per `requestAnimationFrame`, fixing colors progressively.
    /// Called from `injectContent` Phase 2 (dark mode only), not during template load.
    ///
    /// Posts `heightChanged` messages to the native side instead of requiring periodic
    /// `evaluateJavaScript` polling. A `ResizeObserver` on `#emailContent` fires whenever
    /// the content box changes (e.g., after an image loads and expands the layout).
    static func userScriptSource(bgLum: String) -> String {
        """
        var PAGE_BG_LUM = \(bgLum);

        function fixContrastColorsAsync() {
            var MIN_CR = 4.5;

            function linearize(c) {
                c /= 255;
                return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
            }
            function relativeLum(r, g, b) {
                return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
            }
            function contrastBetween(lum1, lum2) {
                var hi = Math.max(lum1, lum2), lo = Math.min(lum1, lum2);
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
            function rgbToHsl(r, g, b) {
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
                return [h, s, l];
            }
            function hslToRgb(h, s, l) {
                if (s === 0) {
                    var v = Math.round(l * 255);
                    return [v, v, v];
                }
                var q2 = l < 0.5 ? l * (1 + s) : l + s - l * s;
                var p2 = 2 * l - q2;
                return [
                    Math.round(hue2rgb(p2, q2, h + 1/3) * 255),
                    Math.round(hue2rgb(p2, q2, h)       * 255),
                    Math.round(hue2rgb(p2, q2, h - 1/3) * 255)
                ];
            }

            function lightenToContrast(r, g, b, bgLum) {
                var hsl = rgbToHsl(r, g, b);
                for (var tl = Math.max(hsl[2] + 0.1, 0.55); tl <= 1.0; tl += 0.04) {
                    var rgb = hslToRgb(hsl[0], hsl[1], tl);
                    if (contrastBetween(relativeLum(rgb[0], rgb[1], rgb[2]), bgLum) >= MIN_CR)
                        return 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
                }
                return '#FFFFFF';
            }

            function darkenToContrast(r, g, b, bgLum) {
                var hsl = rgbToHsl(r, g, b);
                for (var tl = Math.min(hsl[2] - 0.1, 0.45); tl >= 0.0; tl -= 0.04) {
                    var rgb = hslToRgb(hsl[0], hsl[1], tl);
                    if (contrastBetween(relativeLum(rgb[0], rgb[1], rgb[2]), bgLum) >= MIN_CR)
                        return 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
                }
                return '#000000';
            }

            // Cache background luminance per element to avoid redundant ancestor walks.
            var bgCache = new WeakMap();

            function effectiveBgLum(el) {
                if (bgCache.has(el)) return bgCache.get(el);
                var node = el;
                var uncached = [];
                var result = PAGE_BG_LUM;
                while (node) {
                    if (node === document.body || node === document.documentElement) {
                        node = node.parentElement;
                        continue;
                    }
                    if (bgCache.has(node)) { result = bgCache.get(node); break; }
                    var bg = window.getComputedStyle(node).backgroundColor;
                    var rgba = parseRgb(bg);
                    if (rgba) {
                        var parts = bg.slice(bg.indexOf('(') + 1).split(',');
                        var alpha = parts.length >= 4 ? parseFloat(parts[3]) : 1;
                        if (alpha > 0.1) {
                            result = relativeLum(rgba[0], rgba[1], rgba[2]);
                            bgCache.set(node, result);
                            break;
                        }
                    }
                    uncached.push(node);
                    node = node.parentElement;
                }
                for (var k = 0; k < uncached.length; k++) bgCache.set(uncached[k], result);
                bgCache.set(el, result);
                return result;
            }

            // TreeWalker: lazy iteration — no upfront querySelectorAll + Array.from allocation.
            var content = document.getElementById('emailContent');
            if (!content) return;
            var walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT, null);
            var CHUNK = 60;
            function processChunk() {
                var fixes = [];
                var count = 0;
                var node;
                while (count < CHUNK && (node = walker.nextNode())) {
                    count++;
                    var style = window.getComputedStyle(node);
                    if (style.display === 'none' || style.visibility === 'hidden') continue;
                    var c = style.color;
                    var rgb = parseRgb(c);
                    if (!rgb) continue;
                    var cParts = c.slice(c.indexOf('(') + 1).split(',');
                    if (cParts.length >= 4 && parseFloat(cParts[3]) < 0.1) continue;
                    var bgLum = effectiveBgLum(node);
                    var textLum = relativeLum(rgb[0], rgb[1], rgb[2]);
                    if (contrastBetween(textLum, bgLum) >= MIN_CR) continue;
                    fixes.push([node, bgLum > 0.5
                        ? darkenToContrast(rgb[0], rgb[1], rgb[2], bgLum)
                        : lightenToContrast(rgb[0], rgb[1], rgb[2], bgLum)]);
                }
                for (var j = 0; j < fixes.length; j++) {
                    fixes[j][0].style.setProperty('color', fixes[j][1], 'important');
                }
                if (node) { requestAnimationFrame(processChunk); }
            }
            requestAnimationFrame(processChunk);
        }

        // Robust content height measurement -- layered approach:
        // 1. ResizeObserver for layout-driven changes (reflow, font render)
        // 2. Image load/error listeners for async image loading
        // 3. MutationObserver to re-attach image listeners after innerHTML injection
        // Uses scrollHeight (includes padding, overflow) instead of contentRect.height.
        var content = document.getElementById('emailContent');
        if (content) {
            var lastH = 0;
            var heightTimer = null;
            function reportHeight() {
                clearTimeout(heightTimer);
                heightTimer = setTimeout(function() {
                    var h = Math.ceil(content.scrollHeight);
                    if (h > 0 && h !== lastH) {
                        lastH = h;
                        window.webkit.messageHandlers.heightChanged.postMessage(h);
                    }
                }, 16);
            }

            new ResizeObserver(function() {
                reportHeight();
            }).observe(content);

            function observeImages() {
                content.querySelectorAll('img').forEach(function(img) {
                    if (img.complete) return;
                    img.addEventListener('load', reportHeight);
                    img.addEventListener('error', reportHeight);
                });
            }
            observeImages();

            new MutationObserver(function() {
                observeImages();
                requestAnimationFrame(reportHeight);
            }).observe(content, { childList: true, subtree: true });

            reportHeight();
        }
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HTMLEmailView
        /// Whether the template shell has finished loading (didFinish fired).
        var templateReady = false
        var lastColorScheme: ColorScheme?
        /// Tracks the last injected HTML to skip redundant updates.
        var lastContentKey = ""
        var lastAllowRemoteImages = false
        var pendingHTML: String?
        var pendingCSSUpdate: (textHex: String, bgLum: String)?
        weak var webView: WKWebView?

        init(_ parent: HTMLEmailView) { self.parent = parent }

        // MARK: Content Injection

        /// Injects email HTML into the pre-loaded template via parameterized JS.
        /// CSP `script-src 'none'` prevents any scripts in the injected HTML from executing.
        func injectContent(_ html: String) {
            guard let webView else { return }
            Task { @MainActor [weak self] in
                // Phase 1: inject HTML and measure height — show content immediately
                _ = try? await webView.callAsyncJavaScript(
                    "document.getElementById('emailContent').innerHTML = html;"
                    + "if (typeof reportHeight === 'function') {"
                    + "  requestAnimationFrame(function() { reportHeight(); });"
                    + "}",
                    arguments: ["html": html],
                    contentWorld: .page
                )
                self?.parent.isContentLoaded = true

                // Phase 2: fix contrast asynchronously (both light and dark mode).
                // Emails with inline styles (LinkedIn, marketing) can have white text on
                // light backgrounds or dark text on dark backgrounds in either mode.
                _ = try? await webView.callAsyncJavaScript(
                    "if (typeof fixContrastColorsAsync === 'function') { fixContrastColorsAsync(); }",
                    arguments: [:],
                    contentWorld: .page
                )
            }
        }

        /// Updates CSS custom properties and re-runs contrast fix for color scheme changes.
        func updateColorScheme(textHex: String, bgLum: String) {
            guard let webView else { return }
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "document.documentElement.style.setProperty('--text-color', textHex);"
                    + "PAGE_BG_LUM = parseFloat(bgLum);"
                    + "if (typeof fixContrastColorsAsync === 'function') { fixContrastColorsAsync(); }",
                    arguments: ["textHex": textHex, "bgLum": bgLum],
                    contentWorld: .page
                )
            }
        }

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
                guard let self else { return }
                self.parent.contentHeight = height
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            templateReady = true

            // Apply pending CSS variable update from makeNSView.
            if let css = pendingCSSUpdate {
                pendingCSSUpdate = nil
                updateColorScheme(textHex: css.textHex, bgLum: css.bgLum)
            }

            // Inject first email content if it arrived before template was ready.
            if let html = pendingHTML {
                pendingHTML = nil
                injectContent(html)
            } else {
                Task { @MainActor [weak self] in
                    self?.parent.isContentLoaded = true
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if let onOpenLink = parent.onOpenLink {
                    onOpenLink(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            // Only allow the initial template load (before templateReady).
            guard !templateReady,
                  navigationAction.navigationType == .other
            else {
                return .cancel
            }
            return .allow
        }
    }
}
