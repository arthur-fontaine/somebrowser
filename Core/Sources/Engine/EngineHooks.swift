import AppKit
import Foundation
import Observation

/// Extension points features register on. Engines call every hook they can support; a hook an engine
/// cannot support is simply never called (check `BrowserEngine.capabilities`).
public final class EngineHooks {
    public init() {}

    // MARK: Network

    /// Called for every subresource and navigation request **off the main thread** (CEF: IO thread).
    /// Must be fast and thread-safe. First non-`.allow` verdict wins.
    public var requestFilters: [RequestFilter] {
        get { lock.withLock { _requestFilters } }
        set { lock.withLock { _requestFilters = newValue } }
    }
    public func addRequestFilter(_ filter: @escaping RequestFilter) { lock.withLock { _requestFilters.append(filter) } }

    nonisolated public func evaluate(_ request: WebRequest) -> RequestVerdict {
        let filters = lock.withLock { _requestFilters }
        for f in filters {
            let v = f(request)
            if v != .allow { return v }
        }
        return .allow
    }

    nonisolated(unsafe) private var _requestFilters: [RequestFilter] = []
    nonisolated private let lock = NSLock()

    /// WebKit content blockers (Apple JSON format), compiled by the engine. Identifier → JSON.
    public private(set) var contentRuleLists: [String: String] = [:]
    /// Several engines may share these hooks (CEF with WebKit for protected media): each observes.
    private var contentRuleListObservers: [() -> Void] = []
    public func observeContentRuleLists(_ observer: @escaping () -> Void) { contentRuleListObservers.append(observer) }
    /// The engine couldn't compile a rule list (WebKit: over its rule limit, unsupported regex…).
    public var onContentRuleListFailed: ((_ identifier: String, _ error: Error) -> Void)?
    public func setContentRuleList(_ json: String?, identifier: String) {
        contentRuleLists[identifier] = json
        contentRuleListObservers.forEach { $0() }
    }

    // MARK: Scripts

    public private(set) var userScripts: [UserScript] = []
    private var userScriptObservers: [() -> Void] = []
    public func observeUserScripts(_ observer: @escaping () -> Void) { userScriptObservers.append(observer) }
    public func addUserScript(_ script: UserScript) {
        userScripts.append(script)
        userScriptObservers.forEach { $0() }
    }

    /// Scripts for one page: given the URL a main-frame document is about to load, a script to run in it before any of the
    /// page's own scripts, in the page's world (page CSP doesn't apply). Engines ask at the start of each main-frame
    /// navigation and redirect; a script must not assume the page loaded (it may be replaced by a later navigation).
    public private(set) var documentStartScripts: [(URL) -> String?] = []
    public func addDocumentStartScript(_ provider: @escaping (URL) -> String?) {
        documentStartScripts.append(provider)
    }
    /// Called by engines.
    public func documentStartScript(for url: URL) -> String? {
        let scripts = documentStartScripts.compactMap { $0(url) }.filter { !$0.isEmpty }
        return scripts.isEmpty ? nil : scripts.map { "try {\n\($0)\n} catch (e) {}" }.joined(separator: "\n")
    }

    /// Messages posted from pages with `window.__browser.post(name, body)`. Any page script can post any
    /// name and body: treat the body as untrusted input.
    public private(set) var messageHandlers: [String: (EngineTab, ScriptMessage) -> Void] = [:]
    public func handleMessages(named name: String, _ handler: @escaping (EngineTab, Any) -> Void) {
        messageHandlers[name] = { tab, message in handler(tab, message.body) }
    }
    /// Same, with the sender as the engine saw it: use for flows where identity matters (credentials, site policy).
    public func handleFrameMessages(named name: String, _ handler: @escaping (EngineTab, ScriptMessage) -> Void) {
        messageHandlers[name] = handler
    }
    /// Called by engines.
    public func dispatch(_ name: String, from tab: EngineTab, _ message: ScriptMessage) {
        messageHandlers[name]?(tab, message)
    }

    // MARK: Navigation

    /// Main-frame navigation decisions (Sign in with Apple interception, link routing…). First non-`.allow` wins.
    public private(set) var navigationPolicies: [(NavigationAction) -> NavigationPolicy] = []
    public func addNavigationPolicy(_ policy: @escaping (NavigationAction) -> NavigationPolicy) {
        navigationPolicies.append(policy)
    }
    public func decide(_ action: NavigationAction) -> NavigationPolicy {
        for p in navigationPolicies {
            let d = p(action)
            if case .allow = d { continue }
            return d
        }
        return .allow
    }

    // MARK: Permissions

    /// Camera, microphone, location, notifications… First non-nil decision wins; nil from all → `.prompt`.
    public private(set) var permissionHandlers: [(PermissionRequest) -> PermissionDecision?] = []
    public func addPermissionHandler(_ handler: @escaping (PermissionRequest) -> PermissionDecision?) {
        permissionHandlers.append(handler)
    }
    public func decide(_ request: PermissionRequest) -> PermissionDecision {
        for h in permissionHandlers { if let d = h(request) { return d } }
        return .prompt
    }
    /// Shows the native permission prompt when no handler decided. Set by the permissions feature.
    public var permissionPrompt: ((PermissionRequest, @escaping (Bool) -> Void) -> Void)?

    // MARK: Error pages

    /// The browser's own page (HTML) for a main-frame load that failed; nil keeps the engine's. Set by the error pages
    /// feature. Engines show it at the address that failed.
    public var errorPage: ((PageLoadError) -> String?)?
    /// Hosts whose invalid certificate the user chose to accept (this session): engines let their pages load.
    public var acceptedInvalidCertificates: Set<String> = []

    // MARK: Page dialogs

    /// Shows a page's dialog (alert, confirm, prompt, leaving the page, a site's sign-in) in the browser's own UI and
    /// answers once the user did. Set by the dialogs feature; engines fall back to their own dialogs without it.
    public var pageDialog: ((PageDialog, @escaping (PageDialog.Answer) -> Void) -> Void)? {
        didSet { pageDialogObservers.forEach { $0() } }
    }
    private var pageDialogObservers: [() -> Void] = []
    /// Engines that must know beforehand whether the browser shows page dialogs itself.
    public func observePageDialog(_ observer: @escaping () -> Void) {
        pageDialogObservers.append(observer)
        observer()
    }

    // MARK: Downloads

    public private(set) var downloadObservers: [(DownloadEvent) -> Void] = []
    public func observeDownloads(_ observer: @escaping (DownloadEvent) -> Void) { downloadObservers.append(observer) }
    public func emit(_ event: DownloadEvent) { downloadObservers.forEach { $0(event) } }
    /// Chooses where a download is saved. Default: ~/Downloads with a unique name.
    public var downloadDestination: ((URL?, String) -> URL)?

    // MARK: The browser's own requests

    /// Fetches made by engine code (favicons), set by the runtime so Security Core logs them (`OutboundConnections`).
    public var fetch: (@Sendable (URLRequest, _ purpose: String, _ isPrivate: Bool) async throws -> (Data, URLResponse))?

    // MARK: Engine-initiated pages

    /// The engine opened a page on its own (e.g. an extension called `chrome.tabs.create`). The runtime opens it as a tab.
    public var onEngineOpenedURL: ((URL) -> Void)?

    /// Same, when the engine already made the page (it keeps its identity: an extension's tab id lasts). The runtime
    /// adopts it as a tab.
    public var onEngineOpenedPage: ((EngineTab, URL?, OpenDisposition) -> Void)?

    /// The page a new tab shows (an extension's override), nil for the browser's blank new tab. Engines show it for
    /// their own new-tab page.
    public var newTabPage: (() -> URL?)?

    /// The engine wants a live tab made again at `url` (the next `makeTab` may give another kind of page: CEF moves pages
    /// that need protected media to WebKit). The runtime replaces the tab's page in place.
    public var onRecreateTab: ((EngineTab, URL) -> Void)?

    /// The page's context menu asked for a video in Picture in Picture (`source`: the video's address). True when the
    /// browser shows it itself; false (or nil) leaves it to the engine's own window.
    public var pictureInPicture: ((EngineTab, _ source: URL?) -> Bool)?

    // MARK: Keyboard

    /// "Prefer website shortcuts" (Arc): true for a ⌘/⌃ shortcut a focused page should see first. The browser runs it only
    /// if the page doesn't use it, or when it's pressed again right away. Nil (or false): the browser goes first.
    public var pageFirstShortcut: ((NSEvent) -> Bool)?

    // MARK: Search

    /// The user's search engine, for engine UI that searches by itself (Chromium's "Search … for" context menu item).
    public var defaultSearch: DefaultSearchEngine? { didSet { if defaultSearch != oldValue { onDefaultSearchChanged?() } } }
    public var onDefaultSearchChanged: (() -> Void)?

    // MARK: User agent

    /// Brand token appended to the engine's user agent (from `Brand.userAgentBrand` by default).
    public var userAgentBrand: String?
}

public struct DefaultSearchEngine: Equatable, Sendable {
    public var name: String
    /// Search URL with `%s` for the terms.
    public var template: String

    public init(name: String, template: String) {
        self.name = name
        self.template = template
    }
}

/// A page message and its sender, as reported by the engine (never by the page).
public struct ScriptMessage {
    public var body: Any
    /// Sent by the tab's top-level document (not an iframe).
    public var isMainFrame: Bool
    /// URL of the sending frame's document.
    public var frameURL: URL?

    public init(body: Any, isMainFrame: Bool, frameURL: URL?) {
        self.body = body
        self.isMainFrame = isMainFrame
        self.frameURL = frameURL
    }
}

public typealias RequestFilter = @Sendable (WebRequest) -> RequestVerdict

nonisolated public struct WebRequest: Sendable {
    public enum ResourceType: String, Sendable {
        case document, subdocument, stylesheet, script, image, font, xhr, media, websocket, ping, other
    }
    public var url: URL
    /// URL of the top-level document that triggered the request.
    public var documentURL: URL?
    public var type: ResourceType
    public var method: String

    public init(url: URL, documentURL: URL?, type: ResourceType, method: String = "GET") {
        self.url = url
        self.documentURL = documentURL
        self.type = type
        self.method = method
    }
}

nonisolated public enum RequestVerdict: Equatable, Sendable {
    case allow, block
    case redirect(URL)
    /// Answer with this body instead of the network (e.g. a harmless stand-in for a blocked script).
    case respond(mimeType: String, body: Data)
}

public struct UserScript: Sendable {
    public enum InjectionTime: Sendable { case documentStart, documentEnd }
    public enum World: Sendable {
        /// Same JS world as the page (can read page globals).
        case page
        /// Isolated world (WebKit content world; engines without isolation fall back to `.page`).
        case isolated
    }
    public var source: String
    public var injectionTime: InjectionTime
    public var mainFrameOnly: Bool
    public var world: World

    public init(source: String, injectionTime: InjectionTime = .documentEnd, mainFrameOnly: Bool = true, world: World = .isolated) {
        self.source = source
        self.injectionTime = injectionTime
        self.mainFrameOnly = mainFrameOnly
        self.world = world
    }
}

public struct NavigationAction {
    public var url: URL
    public var sourceTab: EngineTab?
    public var isMainFrame: Bool
    public var userGesture: Bool
    /// Modifier keys at click time (⌘, ⇧, ⌥).
    public var modifiers: NSEventModifierFlagsBox
    /// A form sent (a POST, a search, an upload): its data goes with this navigation only, so it can't be redone
    /// elsewhere (in a new tab, by URL).
    public var isFormSubmission: Bool

    public init(url: URL, sourceTab: EngineTab?, isMainFrame: Bool = true, userGesture: Bool = false, modifiers: NSEventModifierFlagsBox = .init(),
                isFormSubmission: Bool = false) {
        self.url = url
        self.sourceTab = sourceTab
        self.isMainFrame = isMainFrame
        self.userGesture = userGesture
        self.modifiers = modifiers
        self.isFormSubmission = isFormSubmission
    }
}

/// Modifier flags without importing AppKit types into every hook signature.
public struct NSEventModifierFlagsBox: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = NSEventModifierFlagsBox(rawValue: 1 << 0)
    public static let shift = NSEventModifierFlagsBox(rawValue: 1 << 1)
    public static let option = NSEventModifierFlagsBox(rawValue: 1 << 2)
    public static let control = NSEventModifierFlagsBox(rawValue: 1 << 3)
}

public enum NavigationPolicy: Equatable {
    case allow
    case cancel
    /// Navigation is taken over by a feature (e.g. native Sign in with Apple), which reports back later.
    case handled
    case openInNewTab(URL)
}

public struct PermissionRequest {
    public enum Kind: String, CaseIterable, Sendable {
        case camera, microphone, location, notifications, clipboard, midi, screenCapture, popups, autoplay
    }
    public var kinds: [Kind]
    public var origin: URL
    public var tab: EngineTab?

    public init(kinds: [Kind], origin: URL, tab: EngineTab?) {
        self.kinds = kinds
        self.origin = origin
        self.tab = tab
    }
}

/// A main-frame load that failed.
public struct PageLoadError {
    public enum Kind: Equatable {
        /// The site's certificate isn't valid (expired, for another name, untrusted…): the page can be visited anyway.
        case certificate
        /// Offline, no such host, refused, timed out…
        case network
    }
    public var url: URL
    public var kind: Kind
    /// The engine's description (`net::ERR_…` name or the system's message).
    public var description: String
    public var tab: EngineTab?

    public init(url: URL, kind: Kind, description: String, tab: EngineTab?) {
        self.url = url
        self.kind = kind
        self.description = description
        self.tab = tab
    }
}

/// A dialog a page asks for, shown over its tab.
public struct PageDialog {
    public enum Kind: Equatable {
        case alert, confirm
        case prompt(defaultText: String)
        /// "Leave this page?" (`beforeunload`); `isReload` when the page is being reloaded.
        case leavePage(isReload: Bool)
        /// HTTP authentication for `host` (a proxy when `isProxy`), in `realm`.
        case signIn(host: String, realm: String, isProxy: Bool)
        /// One of the engine's own dialogs (an extension asking for a permission, to be added or removed…), shown by
        /// the browser instead: its lines in `message`, its buttons in order (the last one accepts, the first cancels).
        case engine(title: String, buttons: [String])
    }
    public struct Answer: Equatable {
        public var accepted: Bool
        /// The prompt's text, or the sign-in's username.
        public var text: String?
        public var password: String?
        /// The button chosen, for `.engine` dialogs (nil: the last one if accepted, else the first).
        public var button: Int?
        public init(accepted: Bool, text: String? = nil, password: String? = nil, button: Int? = nil) {
            self.accepted = accepted
            self.text = text
            self.password = password
            self.button = button
        }
    }
    public var kind: Kind
    public var message: String
    /// The page's origin, as shown to the user.
    public var origin: URL?
    /// The page the dialog is over; nil for the selected page of the key window.
    public var tab: EngineTab?
    /// Lets the engine take the dialog back unanswered (it closed on its own).
    public var withdrawal: DialogWithdrawal?

    public init(kind: Kind, message: String, origin: URL?, tab: EngineTab?, withdrawal: DialogWithdrawal? = nil) {
        self.kind = kind
        self.message = message
        self.origin = origin
        self.tab = tab
        self.withdrawal = withdrawal
    }
}

/// Handed to the browser with a dialog the engine may take back.
public final class DialogWithdrawal {
    public var onWithdraw: (() -> Void)?
    public private(set) var isWithdrawn = false
    public init() {}
    public func withdraw() {
        guard !isWithdrawn else { return }
        isWithdrawn = true
        onWithdraw?()
    }
}

public enum PermissionDecision {
    case grant, deny, prompt
}

public enum DownloadEvent {
    case started(DownloadItem)
    case progress(DownloadItem)
    case finished(DownloadItem)
    case failed(DownloadItem, String)
}

@Observable
public final class DownloadItem: Identifiable {
    public let id = UUID()
    public var sourceURL: URL?
    public var suggestedFilename: String
    public var destination: URL?
    public var receivedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var isFinished = false
    public var error: String?
    public var startedAt = Date()
    public var cancel: (() -> Void)?

    public init(sourceURL: URL?, suggestedFilename: String) {
        self.sourceURL = sourceURL
        self.suggestedFilename = suggestedFilename
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0
    }
}
