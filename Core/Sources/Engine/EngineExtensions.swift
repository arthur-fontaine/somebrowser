import Foundation

/// An installed browser extension, as the engine reports it.
nonisolated public struct BrowserExtension: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// File URL of the toolbar icon, if any.
    public var icon: URL?
    /// Pinned to the toolbar by the user (shown as its own button).
    public var isPinned: Bool
    /// Installed from the Chrome Web Store (so it can be installed again from there).
    public var isFromWebStore = false
    /// The side panel's page (`side_panel.default_path`), relative to the extension.
    public var sidePanelPath: String?
    /// Its toolbar button opens the side panel (`sidePanel.setPanelBehavior({ openPanelOnActionClick: true })`).
    public var opensSidePanelOnClick = false
    /// The page it puts in place of the new tab page (`chrome_url_overrides.newtab`), relative to the extension.
    public var newTabPagePath: String?

    public init(id: String, name: String, icon: URL? = nil, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isPinned = isPinned
    }

    /// One of the extension's pages: `chrome-extension://<id>/<path>`.
    public func page(_ path: String) -> URL? {
        URL(string: "chrome-extension://\(id)/" + (path.hasPrefix("/") ? String(path.dropFirst()) : path))
    }
}

/// Engines that run Chrome extensions (optional; check `context.engine as? EngineExtensions`).
/// Actions go through the engine's own toolbar machinery so popups, `action.onClicked` and the
/// `activeTab` grant behave exactly as in Chrome.
public protocol EngineExtensions: AnyObject {
    /// Enabled extensions, pinned first (in pin order), then by name.
    var installedExtensions: [BrowserExtension] { get }
    /// Called on the main thread when extensions are installed, removed, toggled or (un)pinned.
    var onExtensionsChanged: (() -> Void)? { get set }
    /// Runs the extension's toolbar action for `tab`. Returns false when it cannot (e.g. no toolbar host).
    @discardableResult func runAction(of extensionID: String, in tab: EngineTab) -> Bool
    /// Shows the engine's extensions menu (pin, options, site access, manage) for `tab`.
    @discardableResult func showExtensionsMenu(in tab: EngineTab) -> Bool
    /// The text extensions show on their action in `tab` (`action.setBadgeText`), by extension id.
    func actionBadges(in tab: EngineTab) -> [String: String]
}

public extension EngineExtensions {
    func actionBadges(in tab: EngineTab) -> [String: String] { [:] }
}
