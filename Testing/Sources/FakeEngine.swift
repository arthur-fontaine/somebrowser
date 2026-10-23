import AppKit
import BrowserCore
import Foundation

/// In-memory engine for unit tests: navigation, titles, popups, media and extensions are simulated synchronously.
public final class FakeEngine: BrowserEngine, EngineExtensions, EngineFloating {
    public let id = "fake"
    public var capabilities: EngineCapabilities = [.requestBlocking, .reparentableViews]
    public let hooks = EngineHooks()
    public private(set) var createdTabs: [FakeEngineTab] = []
    public private(set) var viewports: [FakeViewport] = []
    /// Loads stay in progress until the tab's `finishLoad()` (pages that take time).
    public var holdsLoads = false
    /// What `addCookies` was given.
    public private(set) var addedCookies: [BrowserCookie] = []

    public init(options: [String: SettingValue] = [:]) {}

    public func bootstrap(profileDirectory: URL) throws {}
    public func runMainLoop(ready: @escaping () -> Void) { ready() }

    public func makeViewport(in container: NSView) -> EngineViewport {
        let v = FakeViewport()
        viewports.append(v)
        return v
    }

    public func makeTab(_ request: EngineTabRequest) -> EngineTab {
        let t = FakeEngineTab(engine: self)
        createdTabs.append(t)
        // Like real engines, the first commit arrives after the runtime attached its delegate.
        if let url = request.url { t.pendingURL = url }
        return t
    }

    public func shutdown(completion: @escaping () -> Void) { completion() }

    // MARK: Floating

    public private(set) var floatingTabs: [ObjectIdentifier] = []

    public func detachForFloating(_ tab: EngineTab) -> FloatingContent? {
        floatingTabs.append(ObjectIdentifier(tab))
        return .view(NSView())
    }

    public func reattachAfterFloating(_ tab: EngineTab) { floatingTabs.removeAll { $0 == ObjectIdentifier(tab) } }

    // MARK: Extensions (simulated)

    /// Set with `simulateExtensions`; `toolbarAvailable = false` mimics an engine without an action host.
    public private(set) var installedExtensions: [BrowserExtension] = []
    public var onExtensionsChanged: (() -> Void)?
    public var toolbarAvailable = true
    /// What `actionBadges(in:)` reports (extension id → badge text).
    public var badges: [String: String] = [:]
    public private(set) var ranActions: [(id: String, tab: FakeEngineTab)] = []

    public func simulateExtensions(_ list: [BrowserExtension]) {
        installedExtensions = list
        onExtensionsChanged?()
    }

    /// Managing extensions: the details given back, and each change asked for ("enabled <id> false"…).
    public var extensionDetails: [String: ExtensionDetails] = [:]
    public private(set) var managementCalls: [String] = []

    public func details(of extensionID: String, completion: @escaping (ExtensionDetails?) -> Void) { completion(extensionDetails[extensionID]) }

    public func setEnabled(_ extensionID: String, _ enabled: Bool) {
        managementCalls.append("enabled \(extensionID) \(enabled)")
        extensionDetails[extensionID]?.isEnabled = enabled
        if let i = installedExtensions.firstIndex(where: { $0.id == extensionID }) {
            installedExtensions[i].isEnabled = enabled
            onExtensionsChanged?()
        }
    }

    public func setSiteAccess(_ extensionID: String, _ access: ExtensionDetails.SiteAccess) {
        managementCalls.append("access \(extensionID) \(access.rawValue)")
        extensionDetails[extensionID]?.siteAccess = access
    }

    public func setAllowedInPrivate(_ extensionID: String, _ allowed: Bool) {
        managementCalls.append("private \(extensionID) \(allowed)")
        extensionDetails[extensionID]?.allowedInPrivate = allowed
    }

    public func remove(_ extensionID: String) { managementCalls.append("remove \(extensionID)") }

    /// Applies the request filters exactly like a real engine would.
    public func simulateRequest(_ url: URL, type: WebRequest.ResourceType = .script, documentURL: URL? = nil) -> RequestVerdict {
        hooks.evaluate(WebRequest(url: url, documentURL: documentURL, type: type))
    }
}

public final class FakeViewport: EngineViewport {
    public private(set) var presentedTab: EngineTab?
    public private(set) var presentCount = 0
    public private(set) var focusCount = 0

    public func present(_ tab: EngineTab?) {
        presentedTab = tab
        presentCount += 1
    }
    public func layoutDidChange() {}
    public func focusContent() { focusCount += 1 }
    public func tearDown() { presentedTab = nil }
}

public final class FakeEngineTab: EngineTab {
    public let state = EngineTabState()
    public weak var delegate: EngineTabDelegate? {
        didSet { if delegate != nil, let url = pendingURL { pendingURL = nil; load(url) } }
    }
    var pendingURL: URL? {
        didSet { if let url = pendingURL { state.url = url } }
    }
    public private(set) weak var engine: FakeEngine?
    public private(set) var history: [URL] = []
    public private(set) var historyIndex = -1
    public private(set) var evaluatedScripts: [String] = []
    public private(set) var isClosed = false
    public var zoomFactor: Double = 1
    public var isMuted = false { didSet { state.isMuted = isMuted } }
    /// Value returned by `evaluateJavaScript`.
    public var scriptResult: Any?

    init(engine: FakeEngine) { self.engine = engine }

    public func load(_ url: URL) {
        if engine?.hooks.decide(NavigationAction(url: url, sourceTab: self)) == .some(.cancel) { return }
        history = Array(history.prefix(historyIndex + 1)) + [url]
        historyIndex = history.count - 1
        if engine?.holdsLoads == true {
            heldURL = url
            state.url = url
            state.isLoading = true
            return
        }
        commit(url)
    }

    private var heldURL: URL?

    /// Finishes a load held by `FakeEngine.holdsLoads`.
    public func finishLoad() {
        guard let url = heldURL else { return }
        heldURL = nil
        state.isLoading = false
        commit(url)
    }

    public func loadHTML(_ html: String, baseURL: URL?) {
        state.url = baseURL
        state.title = ""
    }

    /// Simulated loads, in order (url, status, body).
    public private(set) var simulatedLoads: [(url: URL, status: Int, body: Data)] = []
    public func loadSimulated(_ url: URL, response: HTTPURLResponse, body: Data) {
        simulatedLoads.append((url, response.statusCode, body))
        commit(url)
    }

    private func commit(_ url: URL) {
        state.url = url
        state.title = url.host() ?? url.absoluteString
        state.canGoBack = historyIndex > 0
        state.canGoForward = historyIndex < history.count - 1
        state.security = url.scheme == "https" ? .secure : .insecure
        delegate?.engineTab(self, didCommit: url)
        delegate?.engineTabDidFinishLoad(self)
    }

    public func goBack() { guard historyIndex > 0 else { return }; historyIndex -= 1; commit(history[historyIndex]) }
    public func goForward() { guard historyIndex < history.count - 1 else { return }; historyIndex += 1; commit(history[historyIndex]) }
    public func reload(bypassingCache: Bool) { if let u = state.url { commit(u) } }
    public func stopLoading() { state.isLoading = false }

    public func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        evaluatedScripts.append(source)
        completion?(.success(scriptResult))
    }

    public func find(_ text: String, forward: Bool, caseSensitive: Bool) {
        state.findResult = FindResult(matches: text.isEmpty ? 0 : 3, activeIndex: forward ? 1 : 3)
    }
    public func stopFinding() { state.findResult = nil }
    public private(set) var devToolsPanels: [DevToolsPanel] = []
    public func showDevTools(_ panel: DevToolsPanel) { devToolsPanels.append(panel) }
    public private(set) var savePageCount = 0
    public func savePage() { savePageCount += 1 }
    public private(set) var printCount = 0
    public func printPage() { printCount += 1 }
    /// What `snapshot` gives (nil: the page can't be captured).
    public var snapshotImage: NSImage?
    public func snapshot(maxWidth: CGFloat, completion: @escaping (NSImage?) -> Void) { completion(snapshotImage) }

    public func restorationData() -> Data? {
        try? JSONEncoder().encode(["urls": history.map(\.absoluteString), "index": [String(historyIndex)]])
    }

    public func close() { isClosed = true }

    // MARK: Simulation

    /// The page opens a link in a new tab / popup.
    @discardableResult
    public func simulateOpen(_ url: URL, disposition: OpenDisposition = .foregroundTab, userGesture: Bool = true) -> FakeEngineTab {
        let t = FakeEngineTab(engine: engine!)
        engine?.recordCreated(t)
        delegate?.engineTab(self, didOpen: t, url: url, disposition: disposition, userGesture: userGesture)
        t.load(url)
        return t
    }

    public func simulateTitle(_ title: String) { state.title = title }
    public func simulateMedia(audio: Bool, video: Bool) {
        state.isPlayingAudio = audio
        state.isPlayingVideo = video
    }
    /// A page message; `frameURL` defaults to the tab's URL (or an iframe's when `mainFrame` is false).
    public func simulateScriptMessage(_ name: String, body: Any, mainFrame: Bool = true, frameURL: URL? = nil) {
        engine?.hooks.dispatch(name, from: self, ScriptMessage(body: body, isMainFrame: mainFrame, frameURL: frameURL ?? state.url))
    }
}

extension FakeEngine {
    @discardableResult public func runAction(of extensionID: String, in tab: EngineTab) -> Bool {
        guard toolbarAvailable, installedExtensions.contains(where: { $0.id == extensionID }), let tab = tab as? FakeEngineTab else { return false }
        ranActions.append((extensionID, tab))
        return true
    }

    public func setPinned(_ extensionID: String, _ pinned: Bool) {
        guard let i = installedExtensions.firstIndex(where: { $0.id == extensionID }) else { return }
        installedExtensions[i].isPinned = pinned
        onExtensionsChanged?()
    }

    public func actionBadges(in tab: EngineTab) -> [String: String] { badges }

    func recordCreated(_ t: FakeEngineTab) { createdTabs.append(t) }
}

/// Cookies set from outside a page are kept, in order.
extension FakeEngine: EngineCookieStore {
    public func addCookies(_ cookies: [BrowserCookie]) async -> Int {
        addedCookies += cookies
        return cookies.count
    }
}
