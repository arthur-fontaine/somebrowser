import AppKit
import Foundation
import Observation

public typealias NodeID = UUID

/// A tab in the sidebar tree. Persistent fields survive restarts; `engineTab` is the running page,
/// nil while the tab is discarded (hibernated) or not yet loaded.
@Observable
public final class BrowserTab: Identifiable {
    public let id: NodeID
    public var url: URL?
    public var title: String
    public var faviconURL: URL?
    public var favicon: NSImage?
    /// Name chosen by the user (double-click to rename).
    public var customTitle: String?
    /// Home URL of a pinned/favorite tab; navigating away shows a "/" marker and clicking the favicon resets.
    public var pinnedURL: URL?
    public var createdAt: Date
    public var lastActiveAt: Date
    /// Tree: children hidden.
    public var isCollapsed: Bool
    /// Horse's ⌘Y: links open in this tab instead of as children.
    public var opensLinksInPlace: Bool
    /// Engine navigation history for restore.
    public var restorationData: Data?
    public var isPrivate: Bool

    /// Live engine page (not persisted).
    public internal(set) var engineTab: EngineTab?
    /// When an agent (Claude) last acted on the page: navigated, clicked, typed, scrolled (not persisted). It counts as
    /// working on it for `agentActivityWindow` after, which covers the steps it takes unseen (reading, screenshots).
    public var agentActedAt: Date?
    public static let agentActivityWindow: TimeInterval = 5

    public init(id: NodeID = UUID(), url: URL?, title: String = "", faviconURL: URL? = nil, createdAt: Date = Date(),
                isPrivate: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.createdAt = createdAt
        self.lastActiveAt = createdAt
        self.isCollapsed = false
        self.opensLinksInPlace = false
        self.isPrivate = isPrivate
    }

    public var live: EngineTabState? { engineTab?.state }
    public var isLoaded: Bool { engineTab != nil }

    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let live = engineTab?.state.title, !live.isEmpty { return live }
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        // A blank tab shows the start page (Safari's name); "New Tab" is the action that opens one.
        return "Start Page"
    }

    /// Pinned/favorite tab currently away from its home URL.
    public var hasNavigatedAwayFromPin: Bool {
        guard let pinnedURL, let url else { return false }
        return URLNormalizer.key(for: pinnedURL) != URLNormalizer.key(for: url)
    }
}

/// A sidebar folder (Arc). Folders hold tabs and folders; they never auto-archive.
@Observable
public final class Folder: Identifiable {
    public let id: NodeID
    public var name: String
    public var icon: String?
    public var isCollapsed: Bool

    public init(id: NodeID = UUID(), name: String, icon: String? = nil, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isCollapsed = isCollapsed
    }
}

public enum SidebarSection: String, Codable, Sendable, CaseIterable {
    /// Above the divider: kept forever.
    case pinned
    /// Below the divider: new tabs, auto-archived when idle.
    case today
}

/// The kinds of space. The user's own tabs live in the normal space, the only one most of the time. A private space
/// (tabs that keep nothing, locked behind Touch ID whenever left) and a Claude space (the tabs Claude controls) exist
/// while they hold tabs; the sidebar shows a switcher only then.
public enum SpaceKind: String, Codable, Sendable, CaseIterable {
    case normal, `private`, claude

    /// The user opens and navigates tabs here. The Claude space holds only the tabs Claude drives: a tab the user opens
    /// while it's showing goes to the normal space, and its addresses can't be edited.
    public var isUserDriven: Bool { self != .claude }
}

/// A set of pinned and today tabs (Arc Spaces / Horse Trailheads), one per kind.
@Observable
public final class Space: Identifiable {
    public let id: UUID
    public let kind: SpaceKind
    public internal(set) var pinned: [NodeID]
    public internal(set) var today: [NodeID]
    /// The latest `agentActedAt` of its tabs (not persisted).
    public var agentActedAt: Date?

    public init(id: UUID = UUID(), kind: SpaceKind = .normal, pinned: [NodeID] = [], today: [NodeID] = []) {
        self.id = id
        self.kind = kind
        self.pinned = pinned
        self.today = today
    }

    public func roots(_ section: SidebarSection) -> [NodeID] {
        section == .pinned ? pinned : today
    }
}

/// Canonical URL keys for dedup (Horse: opening a URL already in the tree focuses it).
public enum URLNormalizer {
    public static func key(for url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.host?.hasPrefix("www.") == true { c.host = String(c.host!.dropFirst(4)) }
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        var path = c.percentEncodedPath
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        c.percentEncodedPath = path
        if c.scheme == "http" { c.scheme = "https" }
        return c.string ?? url.absoluteString
    }
}
