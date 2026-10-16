import Foundation

/// An installed browser extension, as the engine reports it.
nonisolated public struct BrowserExtension: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// File URL of the toolbar icon, if any.
    public var icon: URL?
    /// Shown in the sidebar (its own button), as the user chose.
    public var isPinned: Bool
    /// Installed from the Chrome Web Store (so it can be installed again from there).
    public var isFromWebStore = false
    /// The side panel's page (`side_panel.default_path`), relative to the extension.
    public var sidePanelPath: String?
    /// Its toolbar button opens the side panel (`sidePanel.setPanelBehavior({ openPanelOnActionClick: true })`).
    public var opensSidePanelOnClick = false
    /// The page it puts in place of the new tab page (`chrome_url_overrides.newtab`), relative to the extension.
    public var newTabPagePath: String?
    /// Its options page (`options_ui.page` or `options_page`), relative to the extension.
    public var optionsPath: String?
    /// Turned on (a turned-off one runs nothing and shows no button).
    public var isEnabled = true

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

/// One extension as Chrome's extensions page shows it, for the browser's own panel.
nonisolated public struct ExtensionDetails: Equatable, Sendable {
    /// When it may read and change sites (Chrome's "Site access").
    public enum SiteAccess: String, CaseIterable, Sendable {
        case onClick = "ON_CLICK", onSpecificSites = "ON_SPECIFIC_SITES", onAllSites = "ON_ALL_SITES"
    }
    public var id: String
    public var version: String
    public var summary: String
    public var isEnabled: Bool
    /// nil when it asks for no sites.
    public var siteAccess: SiteAccess?
    /// What it can do, in Chrome's words ("Read and change your bookmarks").
    public var permissions: [String]
    public var allowedInPrivate: Bool
    /// The user may turn it off or remove it (it isn't installed by policy).
    public var isUserModifiable: Bool

    public init(id: String, version: String, summary: String, isEnabled: Bool, siteAccess: SiteAccess?, permissions: [String],
                allowedInPrivate: Bool, isUserModifiable: Bool) {
        self.id = id
        self.version = version
        self.summary = summary
        self.isEnabled = isEnabled
        self.siteAccess = siteAccess
        self.permissions = permissions
        self.allowedInPrivate = allowedInPrivate
        self.isUserModifiable = isUserModifiable
    }
}

/// Engines that run Chrome extensions (optional; check `context.engine as? EngineExtensions`).
/// Actions go through the engine's own toolbar machinery so popups, `action.onClicked` and the
/// `activeTab` grant behave exactly as in Chrome.
public protocol EngineExtensions: AnyObject {
    /// Installed extensions (turned-off ones too, `isEnabled` false), pinned first (in pin order), then by name.
    var installedExtensions: [BrowserExtension] { get }
    /// Called on the main thread when extensions are installed, removed, toggled or (un)pinned.
    var onExtensionsChanged: (() -> Void)? { get set }
    /// Runs the extension's toolbar action for `tab`. Returns false when it cannot (e.g. no toolbar host).
    @discardableResult func runAction(of extensionID: String, in tab: EngineTab) -> Bool
    /// Shows the extension in the sidebar or not (`BrowserExtension.isPinned`).
    func setPinned(_ extensionID: String, _ pinned: Bool)
    /// The text extensions show on their action in `tab` (`action.setBadgeText`), by extension id.
    func actionBadges(in tab: EngineTab) -> [String: String]

    // Managing them (what Chrome's extensions page does).
    func details(of extensionID: String, completion: @escaping (ExtensionDetails?) -> Void)
    func setEnabled(_ extensionID: String, _ enabled: Bool)
    func setSiteAccess(_ extensionID: String, _ access: ExtensionDetails.SiteAccess)
    func setAllowedInPrivate(_ extensionID: String, _ allowed: Bool)
    /// Removes it once the user confirms (in the browser's dialog).
    func remove(_ extensionID: String)
}

public extension EngineExtensions {
    func actionBadges(in tab: EngineTab) -> [String: String] { [:] }
    func details(of extensionID: String, completion: @escaping (ExtensionDetails?) -> Void) { completion(nil) }
    func setEnabled(_ extensionID: String, _ enabled: Bool) {}
    func setSiteAccess(_ extensionID: String, _ access: ExtensionDetails.SiteAccess) {}
    func setAllowedInPrivate(_ extensionID: String, _ allowed: Bool) {}
    func remove(_ extensionID: String) {}
}
