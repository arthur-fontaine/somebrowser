import CoreGraphics
import Foundation
import Observation

/// Per-window state. The tab tree is global (shared by all windows, like Horse); selection, space and
/// layout are per window.
@Observable
public final class BrowserWindowState: Identifiable {
    public let id: UUID
    public internal(set) var spaceID: UUID
    /// The kind of the space shown (`BrowserRuntime.switchSpace` keeps it).
    public internal(set) var spaceKind: SpaceKind
    public internal(set) var selectedTabID: NodeID?
    /// The window shows the private space: new tabs here are private.
    public var isPrivate: Bool { spaceKind == .private }
    /// The private space was unlocked (Touch ID) since the window last entered it; leaving it locks it again.
    public internal(set) var isPrivateUnlocked = false
    /// The private space is shown but locked: its pages and tab titles stay hidden until unlocked.
    public var isLocked: Bool { isPrivate && !isPrivateUnlocked }

    // Layout (features toggle these; the shell lays out accordingly).
    public var isSidebarVisible = true
    /// The sidebar is hidden but still sliding out: its column stays until it has (the page then takes the room).
    public var isSidebarLeaving = false
    /// The sidebar is sliding in (the traffic lights wait for it, then fade in).
    public var isSidebarArriving = false
    /// Sidebar temporarily shown over the content while hidden (edge hover, Horse's "Shelf").
    public var isSidebarPeeking = false
    public var sidebarWidth: CGFloat = 260
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

    public init(id: UUID = UUID(), spaceID: UUID, spaceKind: SpaceKind = .normal) {
        self.id = id
        self.spaceID = spaceID
        self.spaceKind = spaceKind
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
