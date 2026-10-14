import AppKit
import BrowserCore
import CEFBridge
import Foundation

/// One Chromium page: bridges `CEFTabDelegate` callbacks into `EngineTabState` and `EngineHooks`.
final class CEFPage: NSObject, EngineTab, CEFTabDelegate {
    let state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    private(set) var tab: CEFTab?
    private weak var engine: CEFEngine?
    private var evalCallbacks: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var nextEvalID = 1
    private var lastFind = ""

    init(engine: CEFEngine) {
        self.engine = engine
        super.init()
    }

    func attach(_ tab: CEFTab) {
        self.tab = tab
        tab.delegate = self
    }

    func attachBlank() { state.url = nil }

    var window: NSWindow? { tab?.window }

    // MARK: EngineTab

    func load(_ url: URL) { tab?.loadURL(url.absoluteString) }

    func loadHTML(_ html: String, baseURL: URL?) {
        let encoded = Data(html.utf8).base64EncodedString()
        tab?.loadURL("data:text/html;charset=utf-8;base64,\(encoded)")
    }

    func goBack() { tab?.goBack() }
    func goForward() { tab?.goForward() }
    func reload(bypassingCache: Bool) { tab?.reloadIgnoringCache(bypassingCache) }
    func stopLoading() { tab?.stopLoad() }

    /// CEF can't return values from script directly: results come back over `__browser.post('__eval')`.
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        guard let completion else { tab?.executeJavaScript(source); return }
        let id = nextEvalID
        nextEvalID += 1
        evalCallbacks[id] = completion
        let literal = String(data: try! JSONEncoder().encode(source), encoding: .utf8)!
        tab?.executeJavaScript("""
        (async () => { try { const r = await (0, eval)(\(literal)); window.__browser.post('__eval', { id: \(id), ok: true, value: r === undefined ? null : r }); }
          catch (e) { window.__browser.post('__eval', { id: \(id), ok: false, error: String(e) }); } })();
        """)
    }

    var zoomFactor: Double {
        get { pow(1.2, tab?.zoomLevel ?? 0) }
        set { tab?.zoomLevel = log(max(newValue, 0.1)) / log(1.2) }
    }

    var isMuted: Bool {
        get { tab?.muted ?? false }
        set { tab?.muted = newValue; state.isMuted = newValue }
    }

    func find(_ text: String, forward: Bool, caseSensitive: Bool) {
        guard !text.isEmpty else { stopFinding(); return }
        tab?.find(text, forward: forward, matchCase: caseSensitive, findNext: text == lastFind)
        lastFind = text
    }

    func stopFinding() {
        lastFind = ""
        state.findResult = nil
        tab?.stopFinding()
    }

    func showDevTools() { tab?.showDevTools() }

    func snapshot(maxWidth: CGFloat, completion: @escaping (NSImage?) -> Void) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return completion(nil) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        completion(image)
    }

    func restorationData() -> Data? { nil }

    func close() {
        tab?.close()
        tab = nil
        evalCallbacks.removeAll()
    }

    // MARK: CEFTabDelegate

    func cefTab(_ tab: CEFTab, addressChanged url: String) {
        state.url = URL(string: url)
        state.security = Self.security(state.url)
    }

    func cefTab(_ tab: CEFTab, titleChanged title: String) { state.title = title }

    func cefTab(_ tab: CEFTab, faviconChanged url: String?) {
        state.faviconURL = url.flatMap(URL.init(string:))
        state.favicon = nil
        guard let u = state.faviconURL else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: u), let image = NSImage(data: data) else { return }
            await MainActor.run { if self?.state.faviconURL == u { self?.state.favicon = image } }
        }
    }

    func cefTab(_ tab: CEFTab, loadingChanged loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = loading
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        if !loading { state.estimatedProgress = 1 }
    }

    func cefTab(_ tab: CEFTab, progressChanged progress: Double) { state.estimatedProgress = progress }

    func cefTab(_ tab: CEFTab, didCommit url: String) {
        state.isCrashed = false
        state.findResult = nil
        if let u = URL(string: url) { delegate?.engineTab(self, didCommit: u) }
    }

    func cefTabDidFinishLoad(_ tab: CEFTab) { delegate?.engineTabDidFinishLoad(self) }

    func cefTab(_ tab: CEFTab, statusChanged status: String?) {
        state.hoveredLink = status.flatMap { $0.contains("://") ? URL(string: $0) : nil }
    }

    func cefTab(_ tab: CEFTab, mediaAccessVideo video: Bool, audio: Bool) {
        state.isCapturingCamera = video
        state.isCapturingMicrophone = audio
    }

    func cefTab(_ tab: CEFTab, fullscreenChanged fullscreen: Bool) {
        state.isInFullscreen = fullscreen
        if let w = window?.parent, w.styleMask.contains(.fullScreen) != fullscreen { w.toggleFullScreen(nil) }
    }

    func cefTab(_ tab: CEFTab, findResultCount count: Int32, active: Int32) {
        state.findResult = FindResult(matches: Int(count), activeIndex: Int(active))
    }

    func cefTab(_ tab: CEFTab, shouldNavigateTo url: String, userGesture gesture: Bool, isRedirect redirect: Bool) -> Bool {
        guard !redirect, let engine, let u = URL(string: url) else { return true }
        var mods = NSEventModifierFlagsBox()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        switch engine.hooks.decide(NavigationAction(url: u, sourceTab: self, isMainFrame: true, userGesture: gesture, modifiers: mods)) {
        case .allow: return true
        case .cancel, .handled: return false
        case .openInNewTab(let target):
            let page = CEFPage(engine: engine)
            page.attach(CEFTab(url: target.absoluteString, delegate: page))
            delegate?.engineTab(self, didOpen: page, url: target, disposition: .foregroundTab, userGesture: true)
            return false
        }
    }

    func cefTab(_ tab: CEFTab, didOpen newTab: CEFTab, url: String?, disposition: CEFDisposition, userGesture gesture: Bool) {
        guard let engine else { newTab.close(); return }
        let page = CEFPage(engine: engine)
        page.attach(newTab)
        let d: OpenDisposition = switch disposition {
        case .backgroundTab: .backgroundTab
        case .popup: .popup
        case .newWindow: .newWindow
        default: .foregroundTab
        }
        delegate?.engineTab(self, didOpen: page, url: url.flatMap(URL.init(string:)), disposition: d, userGesture: gesture)
    }

    func cefTab(_ tab: CEFTab, message name: String, json: String) {
        let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        switch name {
        case "__eval":
            guard let d = body as? [String: Any], let id = d["id"] as? Int, let cb = evalCallbacks.removeValue(forKey: id) else { return }
            if d["ok"] as? Bool == true { cb(.success(d["value"] is NSNull ? nil : d["value"])) }
            else { cb(.failure(NSError(domain: "JavaScript", code: 1, userInfo: [NSLocalizedDescriptionKey: d["error"] as? String ?? "error"]))) }
        case "__media":
            let d = body as? [String: Any]
            state.isPlayingAudio = d?["audio"] as? Bool ?? false
            state.isPlayingVideo = d?["video"] as? Bool ?? false
        default:
            engine?.hooks.messageHandlers[name]?(self, body)
        }
    }

    func cefTabRequestsClose(_ tab: CEFTab) { delegate?.engineTabDidRequestClose(self) }

    func cefTabDidCrash(_ tab: CEFTab) {
        state.isCrashed = true
        delegate?.engineTabDidCrash(self)
    }

    /// Browser shortcuts (native menu) win over the page; everything else goes to the page.
    func cefTab(_ tab: CEFTab, handleKeyEquivalent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    func cefTab(_ tab: CEFTab, requestsPermissions kinds: [String], origin: String, reply: @escaping (Bool) -> Void) {
        guard let engine, let url = URL(string: origin) else { return reply(false) }
        let request = PermissionRequest(kinds: kinds.compactMap(PermissionRequest.Kind.init(rawValue:)), origin: url, tab: self)
        switch engine.hooks.decide(request) {
        case .grant: reply(true)
        case .deny: reply(false)
        case .prompt:
            if let prompt = engine.hooks.permissionPrompt { prompt(request, reply) } else { reply(false) }
        }
    }

    static func security(_ url: URL?) -> SecurityLevel {
        switch url?.scheme {
        case "https": .secure
        case "http": url?.host() == "localhost" || url?.host() == "127.0.0.1" ? .local : .insecure
        case "file": .local
        case nil: .unknown
        default: .internalPage
        }
    }
}
