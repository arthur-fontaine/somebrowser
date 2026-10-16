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
    /// Bottom bar (spaces switcher, downloads, library).
    static let sidebarFooter: SlotID = "sidebar.footer"
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

        context.commands.handle("sidebar.toggle") { inv in
            guard let w = inv.window else { return }
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
    var dropTarget: (id: NodeID, zone: SidebarLogic.DropZone)?
    var dragging: NodeID?
    /// Interactive two-finger swipe offset (points), per window.
    var swipeOffset: [UUID: CGFloat] = [:]
    /// The docked sidebar sliding in or out, per window: −1 is out of its column, 0 in place.
    var slide: [UUID: CGFloat] = [:]
    @ObservationIgnored private var slideGeneration: [UUID: UUID] = [:]

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    /// Shows or hides the docked sidebar; the window's state changes at once, the slide follows. The page (a window of
    /// its own under Chromium) changes size once, never animated: it makes room before the sidebar slides in, and takes
    /// the room back once it has slid out (`isSidebarLeaving` keeps the column until then).
    func toggle(_ w: BrowserWindowState) {
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Design.Motion.reduced : Design.Motion.layout
        var still = Transaction()
        still.disablesAnimations = true
        let generation = UUID()
        slideGeneration[w.id] = generation
        if w.isSidebarVisible {
            withTransaction(still) {
                w.isSidebarVisible = false
                w.isSidebarLeaving = true
            }
            withAnimation(motion) { slide[w.id] = -1 } completion: { [weak self] in
                guard let self, self.slideGeneration[w.id] == generation else { return }
                withTransaction(still) {
                    w.isSidebarLeaving = false
                    self.slide[w.id] = nil
                }
            }
        } else {
            let leaving = w.isSidebarLeaving
            withTransaction(still) {
                if !leaving { slide[w.id] = -1 }
                w.isSidebarLeaving = false
                w.isSidebarVisible = true
            }
            // Next turn, once the sidebar has been laid out out of view (or from wherever it was leaving).
            DispatchQueue.main.async { [weak self] in
                withAnimation(motion) { self?.slide[w.id] = 0 } completion: {
                    guard let self, self.slideGeneration[w.id] == generation else { return }
                    self.slide[w.id] = nil
                }
            }
        }
    }

    var settings: SettingsStore { runtime.settings }
    var rowHeight: CGFloat { CGFloat(max(24, min(48, settings.int("sidebar.rowHeight")))) }
    static let rowSpacing: CGFloat = 2
}
