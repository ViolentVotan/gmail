import WebKit

/// Wraps a `WKScriptMessageHandler` with a weak reference to break the retain
/// cycle caused by `WKUserContentController` strongly retaining its handlers.
class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}
