import AppKit
import BrowserCore
import CEFBridge
import Foundation

/// One Chromium page: bridges `CEFTabDelegate` callbacks into `EngineTabState` and `EngineHooks`.
final class CEFPage: NSObject, EngineTab, CEFTabDelegate {
    let state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    private(set) var tab: CEFTab?
    /// The viewport showing this page (one at a time).
    weak var presenter: CEFViewport?
    private weak var engine: CEFEngine?
    private var evalCallbacks: [Int: (generation: Int, callback: (Result<Any?, Error>) -> Void)] = [:]
    private var nextEvalID = 1
    /// Bumped on every main-frame commit: scripts sent to a document that went away never answer.
    private var generation = 0
    private var lastFind = ""
    /// History from before a restore (see `RestoredHistory`), and the entry being restored until the browser exists.
    var restored = RestoredHistory()
    var restoring: NavigationEntry?
    private var nativeCanGoBack = false
    private var nativeCanGoForward = false
    /// Commits that move through history rather than start a new one (a new one drops the restored forward list).
    private var historyStepPending = false

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

    func loadSimulated(_ url: URL, response: HTTPURLResponse, body: Data) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        tab?.loadURL(url.absoluteString, simulatingStatus: Int32(response.statusCode),
                  statusText: HTTPURLResponse.localizedString(forStatusCode: response.statusCode), headers: headers, body: body)
    }

    func goBack() {
        historyStepPending = true
        if nativeCanGoBack { tab?.goBack(); return }
        guard let current = currentEntry, let previous = restored.stepBack(from: current) else { historyStepPending = false; return }
        replace(with: previous.url)
    }

    func goForward() {
        historyStepPending = true
        if nativeCanGoForward { tab?.goForward(); return }
        guard let current = currentEntry, let next = restored.stepForward(from: current) else { historyStepPending = false; return }
        replace(with: next.url)
    }

    private var currentEntry: NavigationEntry? { state.url.map { NavigationEntry(url: $0, title: state.title) } }

    /// Shows `url` in place of the current entry; a page that runs no script (error pages) loads it instead.
    private func replace(with url: URL) {
        updateHistoryFlags()
        let literal = String(data: (try? JSONEncoder().encode(url.absoluteString)) ?? Data(), encoding: .utf8) ?? "\"\""
        evaluateJavaScript("location.replace(\(literal))") { [weak self] result in
            if case .failure = result { self?.load(url) }
        }
    }

    private func updateHistoryFlags() {
        state.canGoBack = nativeCanGoBack || !restored.back.isEmpty
        state.canGoForward = nativeCanGoForward || !restored.forward.isEmpty
    }
    func reload(bypassingCache: Bool) { tab?.reloadIgnoringCache(bypassingCache) }
    func stopLoading() { tab?.stopLoad() }

    /// Results come back from the renderer helper as `__eval` messages (V8 Eval, so page CSP doesn't apply).
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        guard let completion else { tab?.executeJavaScript(source); return }
        let id = nextEvalID
        nextEvalID += 1
        evalCallbacks[id] = (generation, completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.failEval(id, "timed out")
        }
        tab?.evaluate(source, identifier: Int32(id))
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

    func showDevTools(_ panel: DevToolsPanel) {
        switch panel {
        case .default: tab?.showDevTools()
        case .console: tab?.runChromeCommand(CEFChromeCommandConsole)
        case .inspectElement: tab?.runChromeCommand(CEFChromeCommandInspect)
        }
    }
    func printPage() { tab?.print() }
    func savePage() { tab?.runChromeCommand(CEFChromeCommandSavePage) }

    /// The visible page in points (its pixels at the screen's scale).
    func snapshot(maxWidth: CGFloat, completion: @escaping (NSImage?) -> Void) {
        guard let tab, let size = window?.contentView?.bounds.size else { return completion(nil) }
        tab.captureScreenshot { png in
            guard let png, let image = NSImage(data: png) else { return completion(nil) }
            image.size = size
            completion(image)
        }
    }

    func restorationData() -> Data? {
        var index = -1
        let native = (tab?.navigationEntries(withCurrentIndex: &index) ?? []).compactMap { entry in
            URL(string: entry["url"] ?? "").map { NavigationEntry(url: $0, title: entry["title"] ?? "") }
        }
        if native.indices.contains(index) { return RestoredHistory.encode(native: native, index: index, around: restored) }
        // Not created yet: what it was restored with.
        return restoring.flatMap { RestoredHistory.encode(native: [$0], index: 0, around: restored) }
    }

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
        guard let u = state.faviconURL, let fetch = engine?.hooks.fetch else { return }
        Task { [weak self, isPrivate = tab.isPrivate] in
            guard let (data, _) = try? await fetch(URLRequest(url: u), "favicon", isPrivate), let image = NSImage(data: data) else { return }
            await MainActor.run { if self?.state.faviconURL == u { self?.state.favicon = image } }
        }
    }

    func cefTab(_ tab: CEFTab, loadingChanged loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = loading
        nativeCanGoBack = canGoBack
        nativeCanGoForward = canGoForward
        updateHistoryFlags()
        if !loading { state.estimatedProgress = 1 }
    }

    func cefTab(_ tab: CEFTab, progressChanged progress: Double) { state.estimatedProgress = progress }

    private func failEval(_ id: Int, _ reason: String) {
        guard let entry = evalCallbacks.removeValue(forKey: id) else { return }
        entry.callback(.failure(NSError(domain: "JavaScript", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])))
    }

    func cefTab(_ tab: CEFTab, didCommit url: String) {
        // Evaluations still pending from the previous document will never answer.
        for (id, entry) in evalCallbacks where entry.generation == generation { _ = id; failEval(id, "page navigated") }
        generation += 1
        if !historyStepPending && restoring == nil { restored.forward = [] }
        restoring = nil
        historyStepPending = false
        updateHistoryFlags()
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

    func cefTab(_ tab: CEFTab, documentStartScriptFor url: String) -> String? {
        URL(string: url).flatMap { engine?.hooks.documentStartScript(for: $0) }
    }

    func cefTab(_ tab: CEFTab, shouldNavigateTo url: String, userGesture gesture: Bool, isRedirect redirect: Bool) -> Bool {
        guard !redirect, let engine, let u = URL(string: url) else { return true }
        var mods = NSEventModifierFlagsBox()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        switch engine.hooks.decide(NavigationAction(url: u, sourceTab: self, isMainFrame: true, userGesture: gesture, modifiers: mods)) {
        case .allow:
            // A site known to need protected media plays in WebKit: this tab becomes a WebKit page there.
            if engine.protectedMedia.needsWebKit(u) {
                engine.hooks.onRecreateTab?(self, u)
                return false
            }
            return true
        case .cancel, .handled: return false
        case .openInNewTab(let target):
            let page = CEFPage(engine: engine)
            page.attach(CEFTab(url: target.absoluteString, delegate: page, private: tab.isPrivate))
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

    func cefTab(_ tab: CEFTab, message name: String, json: String, mainFrame: Bool, frameURL: String?) {
        let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        switch name {
        case "__eval":
            guard let d = body as? [String: Any], let id = d["id"] as? Int, let cb = evalCallbacks.removeValue(forKey: id)?.callback else { return }
            if d["ok"] as? Bool == true { cb(.success(d["value"] is NSNull ? nil : d["value"])) }
            else { cb(.failure(NSError(domain: "JavaScript", code: 1, userInfo: [NSLocalizedDescriptionKey: d["error"] as? String ?? "error"]))) }
        case "__protectedMedia":
            engine?.protectedMediaRequested(by: self)
        case "__media":
            let d = body as? [String: Any]
            state.isPlayingAudio = d?["audio"] as? Bool ?? false
            state.isPlayingVideo = d?["video"] as? Bool ?? false
        default:
            engine?.hooks.dispatch(name, from: self, ScriptMessage(body: body, isMainFrame: mainFrame, frameURL: frameURL.flatMap(URL.init(string:))))
        }
    }

    func cefTabRequestsClose(_ tab: CEFTab) { delegate?.engineTabDidRequestClose(self) }

    func cefTabDidCrash(_ tab: CEFTab) {
        state.isCrashed = true
        delegate?.engineTabDidCrash(self)
    }

    /// Browser shortcuts (native menu) win over the page; everything else goes to the page.
    /// A second press right after the page had its turn goes to the browser.
    private var lastPageFirstKey: (code: UInt16, flags: UInt, at: TimeInterval)?

    func cefTab(_ tab: CEFTab, prefersPageForKey event: NSEvent) -> Bool {
        guard engine?.hooks.pageFirstShortcut?(event) == true else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        if let last = lastPageFirstKey, last.code == event.keyCode, last.flags == flags, event.timestamp - last.at < 0.5 {
            lastPageFirstKey = nil
            return false
        }
        lastPageFirstKey = (event.keyCode, flags, event.timestamp)
        return true
    }

    func cefTab(_ tab: CEFTab, handleKeyEquivalent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    func cefTab(_ tab: CEFTab, dialog kind: String, message: String, defaultText: String, origin: String,
                reply: @escaping (Bool, String?) -> Void) -> Bool {
        guard let show = engine?.hooks.pageDialog else { return false }
        let dialogKind: PageDialog.Kind = switch kind {
        case "confirm": .confirm
        case "prompt": .prompt(defaultText: defaultText)
        case "leave", "reload": .leavePage(isReload: kind == "reload")
        default: .alert
        }
        show(PageDialog(kind: dialogKind, message: message, origin: URL(string: origin), tab: self)) { reply($0.accepted, $0.text) }
        return true
    }

    func cefTab(_ tab: CEFTab, signInFor host: String, realm: String, proxy isProxy: Bool, origin: String,
                reply: @escaping (String?, String?) -> Void) {
        guard let show = engine?.hooks.pageDialog else { return reply(nil, nil) }
        show(PageDialog(kind: .signIn(host: host, realm: realm, isProxy: isProxy), message: "", origin: URL(string: origin), tab: self)) {
            $0.accepted ? reply($0.text ?? "", $0.password ?? "") : reply(nil, nil)
        }
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
