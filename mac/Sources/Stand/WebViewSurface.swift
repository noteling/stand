import AppKit
import StandCore
import WebKit

/// A window of Stand's own to put a page up in. It draws a document itself and loads an
/// address as a browser would, with nothing of anybody's signed in. Nothing has to be
/// allowed for it, and it can be kept off the display, which is how the rehearsals use it.
@MainActor
final class WebViewSurface: NSObject, PageSurface, WKNavigationDelegate {
    let name = "the window “Stand: the screen”"
    let program = "Stand's own window"
    let takesPictures = true
    var animates: Bool { visible }

    private let window: NSWindow
    private let web: WKWebView
    private var loaded: String? // what is in the web view now: a document's key, or an address without its fragment
    private var waiting: CheckedContinuation<Bool, Never>?
    private var waits = 0
    private var status = 200
    private let visible: Bool

    init(visible: Bool) {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.visible = visible
        super.init()
        window.title = "Stand: the screen"
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly // this is the window to share; the panel is the one kept out
        window.contentView = web
        web.navigationDelegate = self
        web.allowsMagnification = true // whoever is beside it may pinch to make the page bigger
        if visible {
            window.center()
            // Where its human put it last time is where it opens the next time.
            window.setFrameAutosaveName("StandScreen")
            window.orderFrontRegardless()
        }
    }

    func close() { window.close() }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Someone closed the window: a page the audience cannot see is not up.
    private func reopen() {
        if visible, !window.isVisible { window.orderFrontRegardless() }
    }

    func load(document name: String, key: String, html: () -> String?) async -> PageLoad {
        reopen()
        if loaded == key { return .held }
        guard let page = html() else { return .failed("The document could not be read.") }
        web.loadHTMLString(page, baseURL: nil)
        guard await finished(within: 4) else {
            loaded = nil
            return .failed("The document did not come up within four seconds.")
        }
        loaded = key
        return .loaded
    }

    func load(address url: URL) async -> PageLoad {
        reopen()
        var bare = URLComponents(url: url, resolvingAgainstBaseURL: false)
        bare?.fragment = nil
        let key = bare?.url?.absoluteString ?? url.absoluteString
        if loaded == key { return .held }
        status = 200
        web.load(URLRequest(url: url, timeoutInterval: 6))
        guard await finished(within: 6) else {
            loaded = nil
            return .failed("The page did not load within six seconds.")
        }
        guard status < 400 else {
            loaded = nil
            return .failed("The address answered \(status).")
        }
        loaded = key
        return .loaded
    }

    func forget() { loaded = nil }

    /// A page this window drew or loaded can always be asked.
    func blind() async -> String? { nil }

    func run(_ script: String) async -> String? {
        // The call that takes a completion handler: the async one crashes when a script answers with nothing.
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
    }

    func picture() async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Waits for the page that was just asked for to finish loading, at most this long.
    private func finished(within seconds: Double) async -> Bool {
        waits += 1
        let this = waits
        return await withCheckedContinuation { continuation in
            waiting = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if self?.waits == this { self?.done(false) } // still the same wait: it has run out
            }
        }
    }

    private func done(_ loaded: Bool) {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(returning: loaded)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done(false) }
    /// The screen goes where the talk sends it. A link someone clicks in the window is not followed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .linkActivated ? .cancel : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse { status = http.statusCode }
        return .allow
    }
}
