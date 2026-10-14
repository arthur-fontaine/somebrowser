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
            SidebarView(window: window, model: model)
        }
        context.ui.contribute(.overlay, id: "sidebar.peek", order: -10) { window in
            SidebarPeekOverlay(window: window, model: model)
        }

        context.commands.handle("sidebar.toggle") { inv in
            guard let w = inv.window else { return }
            w.isSidebarPeeking = false
            w.isSidebarVisible.toggle()
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

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    var settings: SettingsStore { runtime.settings }
    var rowHeight: CGFloat { CGFloat(max(24, min(48, settings.int("sidebar.rowHeight")))) }
    static let rowSpacing: CGFloat = 2
}
