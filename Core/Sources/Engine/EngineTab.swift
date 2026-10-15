import AppKit
import Foundation
import Observation

/// A live page owned by an engine. Persistent tab data lives in `BrowserTab`; this is only the running part,
/// created on demand and dropped when a tab is discarded.
public protocol EngineTab: AnyObject {
    var state: EngineTabState { get }
    var delegate: EngineTabDelegate? { get set }

    func load(_ url: URL)
    /// Internal pages (new tab page, error pages). `baseURL` decides the page's origin.
    func loadHTML(_ html: String, baseURL: URL?)
    /// Navigates to `url` but answers with this response instead of the network: the page gets `url`'s real
    /// origin (Sign in with Apple hands back the page appleid.apple.com would have served).
    func loadSimulated(_ url: URL, response: HTTPURLResponse, body: Data)
    func goBack()
    func goForward()
    func reload(bypassingCache: Bool)
    func stopLoading()

    /// Runs in the main frame's page world, exempt from the page's CSP. The completion receives the script's
    /// completion value as JSON-compatible types; promises are not awaited (post a message instead).
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?)

    var zoomFactor: Double { get set }
    var isMuted: Bool { get set }

    func find(_ text: String, forward: Bool, caseSensitive: Bool)
    func stopFinding()

    /// Developer tools for the page, opened on `panel`.
    func showDevTools(_ panel: DevToolsPanel)
    /// The system print panel for the page.
    func printPage()
    /// Saves the page to a file the user picks (the engine's own save panel).
    func savePage()
    func snapshot(maxWidth: CGFloat, completion: @escaping (NSImage?) -> Void)
    /// Navigation history blob for session restore (nil if unsupported).
    func restorationData() -> Data?
    /// Releases engine resources. The tab must not be used afterwards.
    func close()
}

public extension EngineTab {
    func evaluateJavaScript(_ source: String) { evaluateJavaScript(source, completion: nil) }
}

/// Observable live state, mirrored into `BrowserTab` by the tab runtime.
@Observable
public final class EngineTabState {
    public var url: URL?
    public var title: String = ""
    public var faviconURL: URL?
    public var favicon: NSImage?
    public var isLoading = false
    public var estimatedProgress: Double = 0
    public var canGoBack = false
    public var canGoForward = false
    /// Audio is currently audible.
    public var isPlayingAudio = false
    /// A video element is playing (PiP candidate).
    public var isPlayingVideo = false
    public var isMuted = false
    public var isCapturingCamera = false
    public var isCapturingMicrophone = false
    public var themeColor: NSColor?
    public var security: SecurityLevel = .unknown
    public var hoveredLink: URL?
    public var isCrashed = false
    public var isInFullscreen = false
    public var findResult: FindResult?

    public init() {}
}

public enum SecurityLevel: String, Sendable {
    case unknown, secure, insecure, local, internalPage
}

public struct FindResult: Equatable, Sendable {
    public var matches: Int
    public var activeIndex: Int
    public init(matches: Int, activeIndex: Int) {
        self.matches = matches
        self.activeIndex = activeIndex
    }
}

public enum OpenDisposition: String, Sendable {
    /// ⌘-click / middle-click / `target=_blank` with a gesture.
    case foregroundTab, backgroundTab
    /// `window.open` with features (sized popup), OAuth windows.
    case popup
    case newWindow
}

/// Events from a live tab. All calls happen on the main thread.
/// Where developer tools open.
public enum DevToolsPanel: Sendable {
    case `default`, console, inspectElement
}

public extension EngineTab {
    func showDevTools() { showDevTools(.default) }
}

public protocol EngineTabDelegate: AnyObject {
    /// The page opened another page. The engine already created `newTab` (it may hold an opener reference).
    func engineTab(_ tab: EngineTab, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, userGesture: Bool)
    /// A main-frame navigation committed (history, tree dedup, site settings).
    func engineTab(_ tab: EngineTab, didCommit url: URL)
    /// The page finished loading.
    func engineTabDidFinishLoad(_ tab: EngineTab)
    /// `window.close()` from script.
    func engineTabDidRequestClose(_ tab: EngineTab)
    /// The renderer crashed or was killed.
    func engineTabDidCrash(_ tab: EngineTab)
}

public extension EngineTabDelegate {
    func engineTab(_ tab: EngineTab, didCommit url: URL) {}
    func engineTabDidFinishLoad(_ tab: EngineTab) {}
    func engineTabDidRequestClose(_ tab: EngineTab) {}
    func engineTabDidCrash(_ tab: EngineTab) {}
}
