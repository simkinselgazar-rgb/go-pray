// SceneWebView.swift — the locked-down WKWebView that shows the approved scenes. Owner: lane B.
// Architecture Plan §G "WKWebView lockdown". This is the ONLY file that touches the JS bridge
// (guard.sh: evaluateJavaScript, WKUserContentController, allowingReadAccessTo).
//
// - Loads shield.html from the bundle's scenes folder, read access to that folder only.
// - One navigation is allowed: the one we start. Everything else is cancelled (links, forms,
//   location=, reload, iframes, redirects). No popups, no alert/confirm/prompt, no file picker.
// - Non-persistent data store, no context menu, no drag and drop.
// - Subresources (fetch, script, img, font) are held by the CSP in shield.html.
// - One message handler, `gopray`, four validated message names.
//
// Known limits (accepted by the PM, 2026-10-22):
// - CSP is `style-src 'self' 'unsafe-inline'`: watercolor.js (approved, unedited) writes an inline
//   `style="--d:…"` for the ink-draw timing. Styles cannot reach the network (img/font/connect stay
//   'self'/'none'); script-src stays 'self'.
// - `allowingReadAccessTo` is enforced by the WebContent sandbox, not airtight everywhere: a script in a
//   sibling temp folder still loaded in a test, one under ~/Library/Caches did not. In the signed app
//   bundle nothing can be planted next to the scenes without breaking the signature.

import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.ahmedelgazar.gopray", category: "shield.web")

@MainActor final class SceneWebView: WKWebView {
    enum Failure: Equatable { case processTerminated, navigationFailed(String), scriptFailed(String) }

    static let handlerName = "gopray"

    /// `<bundle>/Contents/Resources/scenes`.
    static var bundledScenesRoot: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("scenes", isDirectory: true)
    }

    let scenesRoot: URL
    var onMessage: ((BridgeMessage) -> Void)?
    var onFailure: ((Failure) -> Void)?
    var onNavigationFinished: (() -> Void)?

    // What the lockdown refused, for tests and logs.
    private(set) var droppedMessages: [String] = []
    private(set) var blockedNavigations: [String] = []
    private(set) var blockedPopups = 0

    /// The one URL we are about to load. Consumed by the first matching navigation.
    fileprivate var expectedNavigation: String?
    private let proxy: Proxy

    init(scenesRoot: URL = SceneWebView.bundledScenesRoot, underPage: NSColor = .black) {
        self.scenesRoot = scenesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let proxy = Proxy()
        self.proxy = proxy

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isElementFullscreenEnabled = false
        cfg.preferences.isTextInteractionEnabled = false
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.userContentController.add(proxy, name: Self.handlerName)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)

        proxy.owner = self
        navigationDelegate = proxy
        uiDelegate = proxy
        underPageBackgroundColor = underPage
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        #if DEBUG
        isInspectable = true
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Loading

    /// `query` has no leading "?". Relative URLs hang the main thread (spike bug 3), so the
    /// string is built from the ABSOLUTE page URL.
    func load(query: String = "", page: String = "shield.html") {
        let base = scenesRoot.appendingPathComponent(page).absoluteString
        guard let url = URL(string: query.isEmpty ? base : base + "?" + query) else { return }
        expectedNavigation = url.absoluteString
        loadFileURL(url, allowingReadAccessTo: scenesRoot)
    }

    /// Stop everything and let go of the handler (which would otherwise retain the proxy).
    func shutDown() {
        stopLoading()
        navigationDelegate = nil
        uiDelegate = nil
        configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        onMessage = nil; onFailure = nil; onNavigationFinished = nil
    }

    // MARK: Swift -> JS (the only evaluateJavaScript calls in the app)

    func show(_ payload: BridgePayload) { run(payload.showScript()) }
    func athanStopped() { run("GoPrayBridge.athanStopped()") }
    /// `.emergency` is a plain fade (no "May Allah accept it."). The argument is one of two fixed strings.
    func dismissPage(kind: EndKind = .confirmed) {
        run(kind == .emergency ? "GoPrayBridge.dismiss(\"emergency\")" : "GoPrayBridge.dismiss()")
    }

    /// `done(true)` once the page has painted its scene as a finished frame (`data-state` lived/still).
    func scenePainted(_ done: @escaping @MainActor (Bool) -> Void) {
        evaluateJavaScript("(function(){ const s = document.getElementById('scene'); if (!s || document.visibilityState !== 'visible') return ''; return getComputedStyle(s).opacity === '1' ? (s.dataset.state || '') : ''; })()") { result, _ in
            let state = result as? String
            done(state == "lived" || state == "still")
        }
    }

    private func run(_ script: String) {
        evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            log.error("script failed: \(String(describing: error), privacy: .public)")
            self?.onFailure?(.scriptFailed(String(describing: error)))
        }
    }

    // MARK: No context menu, no drag and drop

    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    // MARK: Policy helpers

    /// A `file://` URL inside the scenes folder (symlinks resolved, so `..` tricks fail).
    func isInsideScenes(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == scenesRoot.path || path.hasPrefix(scenesRoot.path + "/")
    }

    // MARK: The delegate (one object, weak back to the view so the user content controller cannot leak it)

    @MainActor private final class Proxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var owner: SceneWebView?

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let owner, message.name == SceneWebView.handlerName, message.webView === owner,
                  message.frameInfo.isMainFrame, owner.isInsideScenes(message.frameInfo.request.url) else {
                log.error("message from an untrusted frame dropped")
                owner?.droppedMessages.append("untrusted-frame")
                return
            }
            guard let msg = BridgeMessage.parse(message.body) else {
                let what = String(String(describing: message.body).prefix(80))
                log.error("unknown bridge message dropped: \(what, privacy: .public)")
                owner.droppedMessages.append(what)
                return
            }
            owner.onMessage?(msg)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let owner else { decisionHandler(.cancel); return }
            let url = action.request.url
            if let url, action.targetFrame?.isMainFrame == true, owner.expectedNavigation == url.absoluteString,
               owner.isInsideScenes(url) {
                owner.expectedNavigation = nil
                decisionHandler(.allow)
            } else {
                let what = url?.absoluteString ?? "nil"
                log.error("navigation cancelled: \(what, privacy: .public)")
                owner.blockedNavigations.append(what)
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(owner?.isInsideScenes(response.response.url) == true ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.onNavigationFinished?() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            owner?.onFailure?(.navigationFailed(String(describing: error)))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            owner?.onFailure?(.navigationFailed(String(describing: error)))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { owner?.onFailure?(.processTerminated) }

        // No popups, no dialogs, no file picker, no camera.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            owner?.blockedPopups += 1
            return nil
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
    }
}
