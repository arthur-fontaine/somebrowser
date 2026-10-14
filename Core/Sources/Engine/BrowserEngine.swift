import AppKit
import Foundation

/// A web engine (Chromium via CEF, WebKit, …). The shell and features only ever talk to these protocols;
/// a fork swaps engines with `./forkctl engine use <id>`. See docs/decisions/0001 and 0002.
public protocol BrowserEngine: AnyObject {
    init(options: [String: SettingValue])

    var id: String { get }
    var capabilities: EngineCapabilities { get }

    /// Hooks features register on (request filtering, scripts, popups, permissions, downloads…).
    var hooks: EngineHooks { get }

    /// `NSApplication` subclass the process must use (CEF needs one implementing `CefAppProtocol`).
    static var applicationClass: NSApplication.Type { get }

    /// Called once, after `NSApplication` exists and before any window is created.
    func bootstrap(profileDirectory: URL) throws

    /// Runs the main loop (`NSApp.run()` or the engine's own loop). Calls `ready` once the engine can create tabs.
    func runMainLoop(ready: @escaping () -> Void)

    /// Creates the per-window object that shows the active tab inside `container`.
    func makeViewport(in container: NSView) -> EngineViewport

    /// Creates a live tab. Content starts loading immediately unless `request.url` is nil.
    func makeTab(_ request: EngineTabRequest) -> EngineTab

    /// Orderly shutdown (flush cookies, close browsers). Called from `applicationShouldTerminate`.
    /// Call `completion` to let AppKit terminate, or end `runMainLoop` and exit the process yourself.
    func shutdown(completion: @escaping () -> Void)
}

public extension BrowserEngine {
    static var applicationClass: NSApplication.Type { NSApplication.self }
}

/// Optional: engines that can report and clear per-site data (cookies, storage, cache).
public protocol EngineSiteData: AnyObject {
    /// Approximate bytes stored for a site (nil when the engine cannot tell).
    func dataSize(for site: String) async -> Int64?
    func clearData(for site: String) async
}

public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Chrome extensions (MV3) are supported.
    public static let chromeExtensions = EngineCapabilities(rawValue: 1 << 0)
    /// `chrome://` pages work.
    public static let chromeURLs = EngineCapabilities(rawValue: 1 << 1)
    /// Network requests can be inspected and blocked before they are sent.
    public static let requestBlocking = EngineCapabilities(rawValue: 1 << 2)
    /// Precompiled declarative content rules (WebKit content blockers).
    public static let contentRuleLists = EngineCapabilities(rawValue: 1 << 3)
    /// Several tabs can be visible in one window at once (split view).
    public static let multipleViewportsPerWindow = EngineCapabilities(rawValue: 1 << 4)
    /// Tab content is an NSView that can move between windows/panels (PiP by reparenting).
    public static let reparentableViews = EngineCapabilities(rawValue: 1 << 5)
    /// Developer tools.
    public static let devTools = EngineCapabilities(rawValue: 1 << 6)
    /// Pages live in child windows above the browser window (CEF Chrome style): the shell must draw
    /// anything that floats over web content in overlay windows (see `ShellOverlay`).
    public static let childWindowContent = EngineCapabilities(rawValue: 1 << 7)
}

/// Contract between the shell and child-window engines.
public enum ShellOverlay {
    /// Identifier of shell overlay windows; engines keep them above page windows after re-ordering.
    public static let windowIdentifier = NSUserInterfaceItemIdentifier("browser.overlay")
}

/// Shows one tab at a time inside a shell-owned container view.
public protocol EngineViewport: AnyObject {
    var presentedTab: EngineTab? { get }
    /// Shows `tab` (nil shows nothing). Must be fast: called on every tab switch.
    func present(_ tab: EngineTab?)
    /// Container geometry changed (window resize, sidebar toggle). Engines with child windows reposition them.
    func layoutDidChange()
    /// Gives keyboard focus to the presented page.
    func focusContent()
    /// The window is closing.
    func tearDown()
}

public struct EngineTabRequest {
    public var url: URL?
    /// Tab that opened this one (popups, ⌘-click): engines may share session storage with it.
    public var opener: EngineTab?
    /// Opaque restoration blob from a previous session (navigation history), if the engine supports it.
    public var restorationData: Data?
    /// Private browsing (separate, non-persistent profile).
    public var isPrivate: Bool

    public init(url: URL?, opener: EngineTab? = nil, restorationData: Data? = nil, isPrivate: Bool = false) {
        self.url = url
        self.opener = opener
        self.restorationData = restorationData
        self.isPrivate = isPrivate
    }
}

/// Optional: engines whose tab content can leave the window (system-wide Picture in Picture, Peek).
public protocol EngineFloating: AnyObject {
    /// Takes the tab's content out of its window. `.view` must be embedded by the caller;
    /// `.window` is an engine-owned window the caller may restyle (CEF hosts pages in their own windows).
    func detachForFloating(_ tab: EngineTab) -> FloatingContent?
    /// Gives the content back; the next `EngineViewport.present` shows it in the browser window again.
    func reattachAfterFloating(_ tab: EngineTab)
}

public enum FloatingContent {
    case view(NSView)
    case window(NSWindow)
}
