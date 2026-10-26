import AppKit
import BrowserCore
import SwiftUI

/// Sub-slots the sidebar hosts, so other features place controls inside it without importing it.
public extension SlotID {
    /// Row next to the traffic lights (navigation buttons).
    static let sidebarHeader: SlotID = "sidebar.header"
    /// Address field (Arc keeps the URL in the sidebar).
    static let sidebarAddress: SlotID = "sidebar.address"
    /// Above the space's tabs (e.g. Archive, Safari favorites).
    static let sidebarTop: SlotID = "sidebar.top"
    /// Bottom bar, its leading end (History, Archive).
    static let sidebarFooter: SlotID = "sidebar.footer"
    /// Bottom bar, on the sidebar's axis (the space switcher).
    static let sidebarFooterCenter: SlotID = "sidebar.footer.center"
    /// Bottom bar, its trailing end (Downloads).
    static let sidebarFooterTrailing: SlotID = "sidebar.footer.trailing"
}

public final class SidebarFeature: BrowserFeature {
    let context: FeatureContext
    let model: SidebarModel

    public init(context: FeatureContext) {
        self.context = context
        model = SidebarModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        context.ui.contribute(.sidebar, id: "sidebar.main") { window in
            DockedSidebar(window: window, model: model)
        }
        context.ui.contribute(.overlay, id: "sidebar.peek", order: -10) { window in
            SidebarPeekOverlay(window: window, model: model)
        }

        context.commands.handle("sidebar.toggle", isEnabled: { $0.window?.allowsSidebar ?? true }) { inv in
            guard let w = inv.window, w.allowsSidebar else { return }
            w.isSidebarPeeking = false
            model.toggle(w)
        }
        context.commands.handle("sidebar.focus-mode") { inv in inv.window?.toggle(flag: SidebarModel.focusFlag) }
        context.commands.handle("sidebar.copy-branch-markdown", isEnabled: { $0.window?.selectedTabID != nil }) { [weak self] inv in
            guard let self, let id = inv.window?.selectedTabID else { return }
            let root = self.context.tabs.ancestors(of: id).last ?? id
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SidebarLogic.markdown(for: root, store: self.context.tabs), forType: .string)
            self.context.notify("Copied branch as Markdown", systemImage: "doc.on.doc", window: inv.window)
        }
    }
}

/// Sidebar UI state shared by all windows (hover, drag) — per-window state lives in `BrowserWindowState`.
@Observable
final class SidebarModel {
    static let focusFlag = "sidebar.focus"
    @ObservationIgnored let runtime: BrowserRuntime
    var hovered: NodeID?
    /// Tabs picked with ⇧-click, per window, besides the one shown: the row menu acts on all of them.
    var picked: [UUID: Set<NodeID>] = [:]
    /// The node dragged from any sidebar, and where it would land.
    var dragging: NodeID?
    var dropTarget: DropTarget?
    /// The empty favorites grid, opened by a drag reaching the address field.
    var favoritesOpen = false
    @ObservationIgnored private var dragWatch: Timer?
    /// Interactive two-finger swipe offset (points), per window.
    var swipeOffset: [UUID: CGFloat] = [:]
    /// The docked sidebar's slide in or out, per window, run by its column (`SidebarSlideHost`) in Core Animation.
    var slides: [UUID: Slide] = [:]
    @ObservationIgnored private var slideGeneration: [UUID: UUID] = [:]
    /// Windows whose space a swipe just changed (the pager doesn't slide them again).
    @ObservationIgnored var swiped: Set<UUID> = []

    /// A slide of the docked sidebar: its offset in sidebar widths (−1 is out of its column, 0 in place).
    struct Slide: Equatable {
        let id = UUID()
        let to: CGFloat
        let duration: TimeInterval
        /// Cubic Bézier control points.
        let curve: [Float]
        /// Under Reduce Motion: a fade instead.
        let fades: Bool
        let finished: (@MainActor () -> Void)?

        static func == (a: Slide, b: Slide) -> Bool { a.id == b.id }
    }

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    /// Where a drop's mark comes from: a list of rows, the empty space under one (drawn by the list), or the New Tab row
    /// (the end of pinned above it, Today's start below). Each target clears only its own mark.
    enum DropOwner: Hashable {
        case list(Container), end(Container), newTab

        var drawnBy: DropOwner {
            if case .end(let c) = self { return .list(c) }
            return self
        }
    }

    struct DropTarget: Equatable {
        let owner: DropOwner
        let placement: SidebarLogic.DropPlacement
    }

    /// The picked tabs in the order shown, or none if fewer than two still show.
    func picks(in window: BrowserWindowState) -> [NodeID] {
        guard let picked = picked[window.id], picked.count > 1 else { return [] }
        let ids = TabList.shownRows(in: window, store: runtime.tabs).map(\.id).filter(picked.contains)
        return ids.count > 1 ? ids : []
    }

    func clearPicks(in window: BrowserWindowState) {
        if picked[window.id] != nil { picked[window.id] = nil }
    }

    func beginDrag(_ id: NodeID) {
        dragging = id
        releasedAt = nil
        dragWatch?.invalidate()
        // SwiftUI tells no one when a drag ends away from a drop target (Esc, released outside, on itself). The drop itself
        // can arrive after the button is up (later still while the main thread is busy), so the dragged node outlives the
        // release by a moment: cleared at once, the drop found nothing to move and the tab slid back home.
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { self.releasedAt = nil; return }
                let released = self.releasedAt ?? Date()
                if self.releasedAt == nil {
                    self.releasedAt = released
                    self.dropTarget = nil
                }
                if Date().timeIntervalSince(released) > Self.dropGrace { self.endDrag() }
            }
        }
    }

    @ObservationIgnored private var releasedAt: Date?
    static let dropGrace: TimeInterval = 0.5

    func endDrag() {
        dragWatch?.invalidate()
        dragWatch = nil
        releasedAt = nil
        dropTarget = nil
        dragging = nil
        if favoritesOpen { withAnimation(Design.Motion.layout) { favoritesOpen = false } }
    }

    /// Shows `placement` as `owner`'s mark, or clears the mark if it's `owner`'s.
    func target(_ placement: SidebarLogic.DropPlacement?, by owner: DropOwner) {
        let next = placement.map { DropTarget(owner: owner, placement: $0) }
        if let next, next != dropTarget { dropTarget = next } else if next == nil, dropTarget?.owner == owner { dropTarget = nil }
    }

    /// Shows or hides the docked sidebar; the window's state changes at once, the slide follows. The page (a window of
    /// its own under Chromium) changes size once, never animated: it makes room before the sidebar slides in, and takes
    /// the room back as it finishes sliding out (`isSidebarLeaving` keeps the column until then). The slide runs in
    /// Core Animation, so it keeps moving while Chromium's resize holds the main thread.
    func toggle(_ w: BrowserWindowState) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var still = Transaction()
        still.disablesAnimations = true
        let generation = UUID()
        slideGeneration[w.id] = generation
        if w.isSidebarVisible {
            withTransaction(still) {
                w.isSidebarVisible = false
                w.isSidebarArriving = false
                w.isSidebarLeaving = true
                // Accelerating out.
                slides[w.id] = Slide(to: -1, duration: reduce ? 0.15 : Design.Motion.leaveDuration, curve: [0.42, 0, 1, 1],
                                     fades: reduce, finished: nil)
            }
            // The page (Chromium's) takes ~50 ms to paint at its new size, so it takes the room back that much before the
            // slide ends: it covers the sidebar's last points instead of leaving a gap.
            DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.leaveDuration - 0.05) { [weak self] in
                guard let self, self.slideGeneration[w.id] == generation else { return }
                withTransaction(still) {
                    w.isSidebarLeaving = false
                    self.slides[w.id] = nil
                }
            }
        } else {
            withTransaction(still) {
                w.isSidebarLeaving = false
                w.isSidebarVisible = true
                w.isSidebarArriving = true
                // Spotlight's fast-start curve: no long tail.
                slides[w.id] = Slide(to: 0, duration: reduce ? 0.15 : 0.30, curve: [0.2, 0.8, 0.2, 1], fades: reduce) { [weak self] in
                    guard let self, self.slideGeneration[w.id] == generation else { return }
                    w.isSidebarArriving = false
                    self.slides[w.id] = nil
                }
            }
        }
    }

    var settings: SettingsStore { runtime.settings }
    var rowHeight: CGFloat { CGFloat(max(24, min(48, settings.int("sidebar.rowHeight")))) }
    static let rowSpacing = Design.Space.row
}
