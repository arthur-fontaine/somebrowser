import AppKit
import BrowserCore
import SwiftUI

/// Split View (Arc): the selected tab and a second one side by side. The selected tab keeps the window's content area;
/// the other is shown in a pane beside it (its own viewport, the tab held awake). Selecting the pane's tab swaps the
/// two; selecting any other tab ends the split.
public final class SplitViewFeature: BrowserFeature {
    let context: FeatureContext
    let model = SplitModel()

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        let runtime = context.runtime
        context.commands.handle("split-view.open", isEnabled: { [weak self] inv in
            guard let self, let window = inv.window else { return false }
            return self.model.secondary[window.id] == nil && self.candidate(in: window) != nil
        }) { [weak self] inv in
            guard let self, let window = inv.window, let other = self.candidate(in: window) else { return }
            self.open(other, in: window)
        }
        context.commands.handle("split-view.swap", isEnabled: { [weak self] inv in inv.window.flatMap { self?.model.secondary[$0.id] } != nil }) { [weak self] inv in
            guard let window = inv.window else { return }
            self?.swap(in: window)
        }
        context.commands.handle("split-view.close", isEnabled: { [weak self] inv in inv.window.flatMap { self?.model.secondary[$0.id] } != nil }) { [weak self] inv in
            guard let window = inv.window else { return }
            self?.close(in: window)
        }
        context.events.subscribe(TabSelected.self) { [weak self] e in self?.selected(e) }
        context.events.subscribe(TabsClosed.self) { [weak self] e in
            guard let self else { return }
            for window in self.context.windows where self.model.secondary[window.id].map(e.tabIDs.contains) == true { self.close(in: window) }
        }
        let model = self.model
        context.ui.contribute(.contentTrailing, id: "split-view.pane") { window in SplitPane(model: model, window: window, runtime: runtime) }
        // Above both panes (so the two pages line up): each pane's title, the other one's switches to it.
        context.ui.contribute(.toolbar, id: "split-view.bar", order: 900) { [weak self] window in
            SplitBar(model: model, window: window, runtime: runtime, swap: { self?.swap(in: window) }, close: { self?.close(in: window) })
        }
    }

    /// The tab to split with: the one used before the current one.
    func candidate(in window: BrowserWindowState) -> NodeID? {
        guard let selected = window.selectedTabID else { return nil }
        return window.mru.first { $0 != selected && context.tabs.tab($0) != nil }
    }

    func open(_ tabID: NodeID, in window: BrowserWindowState) {
        guard let tab = context.tabs.tab(tabID), tabID != window.selectedTabID else { return }
        if let old = model.secondary[window.id] { context.runtime.releaseAwake(old, reason: "split") }
        context.runtime.live(tab)
        context.runtime.holdAwake(tabID, reason: "split")
        model.secondary[window.id] = tabID
    }

    func close(in window: BrowserWindowState) {
        guard let id = model.secondary.removeValue(forKey: window.id) else { return }
        context.runtime.releaseAwake(id, reason: "split")
    }

    /// The pane's tab becomes the selected one, and the selected one moves to the pane (`selected` does the move).
    func swap(in window: BrowserWindowState) {
        guard let other = model.secondary[window.id] else { return }
        context.runtime.select(other, in: window)
    }

    func selected(_ e: TabSelected) {
        guard let window = context.runtime.window(e.windowID), let secondary = model.secondary[window.id], e.tabID != e.previousTabID else { return }
        if e.tabID == secondary, let previous = e.previousTabID, context.tabs.tab(previous) != nil {
            open(previous, in: window)
        } else {
            close(in: window)
        }
    }
}

@Observable
final class SplitModel {
    /// Window → the tab in its pane.
    var secondary: [UUID: NodeID] = [:]
}

/// The titles above the two panes: the selected one, and the other (click it to switch).
struct SplitBar: View {
    let model: SplitModel
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    let swap: () -> Void
    let close: () -> Void

    var body: some View {
        if let id = model.secondary[window.id], let other = runtime.tabs.tab(id) {
            HStack(spacing: 6) {
                Text(runtime.selectedTab(in: window)?.displayTitle ?? "").fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(other.displayTitle).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(action: swap) { Image(systemName: "arrow.left.arrow.right") }.help("Switch to this pane (⌃⇧])")
                    Button(action: close) { Image(systemName: "xmark") }.help("Close Split View (⌃⇧-)")
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: swap)
                .frame(maxWidth: .infinity)
                .padding(.leading, 6)
            }
            .font(.callout)
            .lineLimit(1)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 26)
        }
    }
}

/// The pane: the second tab's page.
struct SplitPane: View {
    let model: SplitModel
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        if let id = model.secondary[window.id], let page = runtime.tabs.tab(id)?.engineTab {
            SplitPaneContent(engineTab: page, runtime: runtime)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 6)
        }
    }
}

/// The pane's own engine viewport. Pages move between it and the window's content area on a swap; engines let a page
/// belong to one viewport at a time.
struct SplitPaneContent: NSViewRepresentable {
    let engineTab: EngineTab
    let runtime: BrowserRuntime

    final class Container: NSView {
        var viewport: EngineViewport?
        override func layout() { super.layout(); viewport?.layoutDidChange() }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        DispatchQueue.main.async {
            let viewport = runtime.engine.makeViewport(in: v)
            v.viewport = viewport
            viewport.present(engineTab)
        }
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        if v.viewport?.presentedTab !== engineTab { v.viewport?.present(engineTab) }
    }

    static func dismantleNSView(_ v: Container, coordinator: ()) {
        v.viewport?.tearDown()
    }
}
