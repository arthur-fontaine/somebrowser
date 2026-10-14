import CoreGraphics
import Foundation
import Observation

/// Per-window state. The tab tree is global (shared by all windows, like Horse); selection, space and
/// layout are per window.
@Observable
public final class BrowserWindowState: Identifiable {
    public let id: UUID
    public var spaceID: UUID
    public internal(set) var selectedTabID: NodeID?
    public let isPrivate: Bool

    // Layout (features toggle these; the shell lays out accordingly).
    public var isSidebarVisible = true
    /// Sidebar temporarily shown over the content while hidden (edge hover, Horse's "Shelf").
    public var isSidebarPeeking = false
    public var sidebarWidth: CGFloat = 260
    /// Top toolbar shown (auto-hides on scroll when enabled).
    public var isToolbarVisible = true
    public var isFullscreen = false
    public var isKeyWindow = false
    /// Arbitrary per-window flags features need (e.g. "command-bar.open"), observable.
    public var flags: Set<String> = []
    /// Features that need the traffic lights visible while the sidebar is hidden (toolbar, peek…).
    public var titlebarRequests: Set<String> = []
    /// Web content area in window coordinates (top-left origin), kept by the shell for overlays.
    public var contentFrame: CGRect = .zero
    /// Overlays with text input currently on screen. When the engine hosts pages in child windows, the shell
    /// gives keyboard focus to the overlay window while this is non-empty (use `.overlayKeyboardFocus(_:in:)`).
    public var overlayFocusRequests: Set<String> = []

    /// Most-recently-used tabs, newest first (Ctrl-Tab, selection after close).
    @ObservationIgnored public internal(set) var mru: [NodeID] = []
    /// Engine viewport presenting the selected tab (set by the shell).
    @ObservationIgnored public weak var viewport: EngineViewport?
    /// Saved frame for restoration (`NSStringFromRect`).
    @ObservationIgnored public var frameDescriptor: String?

    public init(id: UUID = UUID(), spaceID: UUID, isPrivate: Bool = false) {
        self.id = id
        self.spaceID = spaceID
        self.isPrivate = isPrivate
    }

    public func toggle(flag: String) {
        if flags.contains(flag) { flags.remove(flag) } else { flags.insert(flag) }
    }

    func noteSelected(_ id: NodeID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 100 { mru.removeLast() }
    }

    func forget(_ ids: Set<NodeID>) {
        mru.removeAll { ids.contains($0) }
        if let s = selectedTabID, ids.contains(s) { selectedTabID = nil }
    }
}
