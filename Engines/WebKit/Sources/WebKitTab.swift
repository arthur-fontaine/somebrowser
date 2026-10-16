import AppKit
import BrowserCore
import UniformTypeIdentifiers
import WebKit

final class WebKitTab: NSObject, EngineTab {
    let state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    let webView: WKWebView
    /// The viewport showing this page (one at a time).
    weak var presenter: WebKitViewport?
    private weak var engine: WebKitEngine?
    /// The current navigation's document-start script and the host it belongs to.
    var documentStartScript: (script: String, host: String)?
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: DownloadItem] = [:]
    private var downloadProgress: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(engine: WebKitEngine, configuration: WKWebViewConfiguration) {
        self.engine = engine
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear
        observe()
    }

    private func observe() {
        let s = state
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { w, _ in s.url = w.url; s.security = Self.security(for: w) },
            webView.observe(\.title, options: [.new]) { w, _ in s.title = w.title ?? "" },
            webView.observe(\.isLoading, options: [.new]) { w, _ in s.isLoading = w.isLoading },
            webView.observe(\.estimatedProgress, options: [.new]) { w, _ in s.estimatedProgress = w.estimatedProgress },
            webView.observe(\.canGoBack, options: [.new]) { w, _ in s.canGoBack = w.canGoBack },
            webView.observe(\.canGoForward, options: [.new]) { w, _ in s.canGoForward = w.canGoForward },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { w, _ in s.security = Self.security(for: w) },
            webView.observe(\.themeColor, options: [.new]) { w, _ in s.themeColor = w.themeColor },
            webView.observe(\.cameraCaptureState, options: [.new]) { w, _ in s.isCapturingCamera = w.cameraCaptureState == .active },
            webView.observe(\.microphoneCaptureState, options: [.new]) { w, _ in s.isCapturingMicrophone = w.microphoneCaptureState == .active },
            webView.observe(\.fullscreenState, options: [.new]) { w, _ in s.isInFullscreen = w.fullscreenState == .inFullscreen },
        ]
    }

    static func security(for w: WKWebView) -> SecurityLevel {
        guard let url = w.url else { return .unknown }
        switch url.scheme {
        case "https": return w.hasOnlySecureContent ? .secure : .insecure
        case "http": return url.host() == "localhost" || url.host() == "127.0.0.1" ? .local : .insecure
        case "file": return .local
        case "about", "data", "blob": return .internalPage
        default: return .internalPage
        }
    }

    // MARK: EngineTab

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func loadHTML(_ html: String, baseURL: URL?) { webView.loadHTMLString(html, baseURL: baseURL) }
    func loadSimulated(_ url: URL, response: HTTPURLResponse, body: Data) {
        webView.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: body)
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload(bypassingCache: Bool) { bypassingCache ? webView.reloadFromOrigin() : webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        webView.evaluateJavaScript(source) { value, error in
            if let error { completion?(.failure(error)) } else { completion?(.success(value)) }
        }
    }

    var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    var isMuted: Bool = false {
        didSet {
            state.isMuted = isMuted
            evaluateJavaScript("""
            (() => { window.__browserMuted = \(isMuted); document.querySelectorAll('video,audio').forEach(m => m.muted = \(isMuted));
              if (!window.__browserMuteHook) { window.__browserMuteHook = true;
                document.addEventListener('play', e => { if (window.__browserMuted) e.target.muted = true; }, true); } })();
            """, completion: nil)
        }
    }

    func find(_ text: String, forward: Bool, caseSensitive: Bool) {
        guard !text.isEmpty else { stopFinding(); return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = caseSensitive
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            guard let self else { return }
            // WebKit does not report a count; ask the page for a cheap approximation.
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            self.evaluateJavaScript("(document.body ? document.body.innerText : '').split('\(escaped)').length - 1") { r in
                let count = (try? r.get()) as? Int ?? (result.matchFound ? 1 : 0)
                let previous = self.state.findResult?.activeIndex ?? 0
                let next = count == 0 ? 0 : (forward ? previous % count + 1 : (previous <= 1 ? count : previous - 1))
                self.state.findResult = FindResult(matches: count, activeIndex: next)
            }
        }
    }

    func stopFinding() {
        state.findResult = nil
        webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()")
    }

    func showDevTools(_ panel: DevToolsPanel) {
        // The inspector is reachable from the context menu ("Inspect Element") once isInspectable is set.
        webView.evaluateJavaScript("console.info('Right-click → Inspect Element to open Web Inspector')")
    }

    /// A web archive, where the user picks.
    func savePage() {
        guard let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (state.title.isEmpty ? "Page" : state.title) + ".webarchive"
        panel.allowedContentTypes = [.webArchive]
        let webView = self.webView
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            webView.createWebArchiveData { result in if case .success(let data) = result { try? data.write(to: url, options: .atomic) } }
        }
    }

    func printPage() {
        guard let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds  // WebKit's print view has no size of its own
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func snapshot(maxWidth: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(min(maxWidth, max(webView.bounds.width, 1))))
        webView.takeSnapshot(with: config) { image, _ in completion(image) }
    }

    func restorationData() -> Data? { webView.interactionState as? Data }

    func close() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        engine?.tabClosed(self)
    }

    func handleInternalMessage(_ name: String, body: Any?) {
        switch name {
        case "__media":
            let d = body as? [String: Any]
            state.isPlayingAudio = d?["audio"] as? Bool ?? false
            state.isPlayingVideo = d?["video"] as? Bool ?? false
        case "__hover":
            state.hoveredLink = (body as? String).flatMap(URL.init(string:))
        case "__favicon":
            if let s = body as? String, let u = URL(string: s) { state.faviconURL = u; loadFavicon(u) }
        default: break
        }
    }

    private func loadFavicon(_ url: URL) {
        guard let engine, let fetch = engine.hooks.fetch else { return }
        let isPrivate = webView.configuration.websiteDataStore !== engine.dataStore
        Task { [weak self] in
            guard let (data, _) = try? await fetch(URLRequest(url: url), "favicon", isPrivate), let image = NSImage(data: data) else { return }
            await MainActor.run { self?.state.favicon = image }
        }
    }
}

// MARK: Navigation

extension WebKitTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url, let engine else { return (.allow, preferences) }
        if action.shouldPerformDownload { return (.download, preferences) }
        let isMain = action.targetFrame?.isMainFrame ?? true
        var mods = NSEventModifierFlagsBox()
        if action.modifierFlags.contains(.command) { mods.insert(.command) }
        if action.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if action.modifierFlags.contains(.option) { mods.insert(.option) }

        // ⌘-click / middle-click: open as a new tab instead of navigating in place.
        if isMain, action.navigationType == .linkActivated, mods.contains(.command) || action.buttonNumber == 2 {
            openNew(url, disposition: mods.contains(.shift) ? .foregroundTab : .backgroundTab, gesture: true)
            return (.cancel, preferences)
        }
        if isMain {
            let policy = engine.hooks.decide(NavigationAction(url: url, sourceTab: self, isMainFrame: true,
                                                              userGesture: action.navigationType == .linkActivated, modifiers: mods))
            switch policy {
            case .allow: break
            case .cancel, .handled: return (.cancel, preferences)
            case .openInNewTab(let target):
                openNew(target, disposition: .foregroundTab, gesture: true)
                return (.cancel, preferences)
            }
            engine.setDocumentStartScript(engine.hooks.documentStartScript(for: url), for: url, in: self)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        state.isCrashed = false
        state.findResult = nil
        if let url = webView.url { delegate?.engineTab(self, didCommit: url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.engineTabDidFinishLoad(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state.isCrashed = true
        delegate?.engineTabDidCrash(self)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { adopt(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { adopt(download) }

    private func openNew(_ url: URL, disposition: OpenDisposition, gesture: Bool) {
        guard let engine else { return }
        let tab = engine.adoptPopup(configuration: engine.makeConfiguration(isPrivate: webView.configuration.websiteDataStore !== engine.dataStore))
        delegate?.engineTab(self, didOpen: tab, url: url, disposition: disposition, userGesture: gesture)
        tab.load(url)
    }
}

// MARK: UI

extension WebKitTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let engine else { return nil }
        let tab = engine.adoptPopup(configuration: configuration)
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
        let disposition: OpenDisposition = sized ? .popup : (action.modifierFlags.contains(.command) ? .backgroundTab : .foregroundTab)
        delegate?.engineTab(self, didOpen: tab, url: action.request.url, disposition: disposition, userGesture: action.navigationType == .linkActivated)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) { delegate?.engineTabDidRequestClose(self) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kinds: [PermissionRequest.Kind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        var comps = URLComponents()
        comps.scheme = origin.protocol
        comps.host = origin.host
        comps.port = origin.port == 0 ? nil : origin.port
        let request = PermissionRequest(kinds: kinds, origin: comps.url ?? URL(string: "about:blank")!, tab: self)
        switch engine?.hooks.decide(request) ?? .prompt {
        case .grant: decisionHandler(.grant)
        case .deny: decisionHandler(.deny)
        case .prompt:
            if let prompt = engine?.hooks.permissionPrompt {
                prompt(request) { decisionHandler($0 ? .grant : .deny) }
            } else {
                decisionHandler(.prompt)
            }
        }
    }

    /// A page's dialog in the browser's own UI (the dialogs feature), else AppKit's alert.
    private func pageDialog(_ kind: PageDialog.Kind, message: String, frame: WKFrameInfo?) async -> PageDialog.Answer {
        let origin = frame.flatMap { URL(string: "\($0.securityOrigin.protocol)://\($0.securityOrigin.host)") } ?? webView.url
        if let show = engine?.hooks.pageDialog {
            return await withCheckedContinuation { done in
                show(PageDialog(kind: kind, message: message, origin: origin, tab: self)) { done.resume(returning: $0) }
            }
        }
        let alert = NSAlert()
        alert.messageText = origin?.host() ?? ""
        alert.informativeText = message
        var field: NSTextField?
        if case .prompt(let text) = kind {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field?.stringValue = text
            alert.accessoryView = field
        }
        if kind != .alert { alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel") }
        let response = alert.runModal()
        return PageDialog.Answer(accepted: response == .alertFirstButtonReturn || kind == .alert, text: field?.stringValue)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await pageDialog(.alert, message: message, frame: frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await pageDialog(.confirm, message: message, frame: frame).accepted
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await pageDialog(.prompt(defaultText: defaultText ?? ""), message: prompt, frame: frame)
        return answer.accepted ? answer.text ?? "" : nil
    }

    /// A site's sign-in (HTTP authentication) in the browser's own dialog; other challenges as WebKit decides.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault].contains(method),
              engine?.hooks.pageDialog != nil, challenge.previousFailureCount < 3 else { return (.performDefaultHandling, nil) }
        let space = challenge.protectionSpace
        let answer = await pageDialog(.signIn(host: space.host, realm: space.realm ?? "", isProxy: space.isProxy()), message: "", frame: nil)
        guard answer.accepted else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: answer.text ?? "", password: answer.password ?? "", persistence: .forSession))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

// MARK: Downloads

extension WebKitTab: WKDownloadDelegate {
    private func adopt(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(sourceURL: download.originalRequest?.url, suggestedFilename: "download")
        item.cancel = { download.cancel { _ in } }
        downloads[ObjectIdentifier(download)] = item
        downloadProgress[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                item.receivedBytes = p.completedUnitCount
                item.totalBytes = p.totalUnitCount
                self?.engine?.hooks.emit(.progress(item))
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = downloads[ObjectIdentifier(download)] else { return nil }
        item.suggestedFilename = suggestedFilename
        item.totalBytes = response.expectedContentLength
        let dest = engine?.hooks.downloadDestination?(item.sourceURL, suggestedFilename) ?? Self.defaultDestination(suggestedFilename)
        item.destination = dest
        engine?.hooks.emit(.started(item))
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        downloadProgress[ObjectIdentifier(download)] = nil
        item.isFinished = true
        item.receivedBytes = max(item.receivedBytes, item.totalBytes)
        engine?.hooks.emit(.finished(item))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        downloadProgress[ObjectIdentifier(download)] = nil
        item.error = error.localizedDescription
        engine?.hooks.emit(.failed(item, error.localizedDescription))
    }

    static func defaultDestination(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// Shows one web view at a time inside the shell's content container.
final class WebKitViewport: EngineViewport {
    private weak var container: NSView?
    private(set) var presentedTab: EngineTab?

    init(container: NSView) { self.container = container }

    /// A page is shown by one viewport at a time (see `CEFViewport.present`).
    func present(_ tab: EngineTab?) {
        let next = tab as? WebKitTab
        if presentedTab === tab, let web = next?.webView, web.superview === container { return }
        if let current = presentedTab as? WebKitTab, current !== next, current.presenter === self {
            current.webView.removeFromSuperview()
            current.presenter = nil
        }
        if let next, let other = next.presenter, other !== self { other.forget(next) }
        presentedTab = tab
        next?.presenter = self
        guard let container, let web = next?.webView else { return }
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web, positioned: .below, relativeTo: nil)
    }

    func layoutDidChange() {
        if let container, let web = (presentedTab as? WebKitTab)?.webView { web.frame = container.bounds }
    }

    func focusContent() {
        if let web = (presentedTab as? WebKitTab)?.webView { web.window?.makeFirstResponder(web) }
    }

    func tearDown() { present(nil) }

    fileprivate func forget(_ tab: WebKitTab) {
        if presentedTab === tab { presentedTab = nil }
    }
}
