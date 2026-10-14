import AppKit
import BrowserCore
import SwiftUI

public final class ToolbarFeature: BrowserFeature {
    let context: FeatureContext
    let model: ToolbarModel

    public init(context: FeatureContext) {
        self.context = context
        model = ToolbarModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        context.ui.contribute(.toolbar, id: "toolbar.layout") { window in
            if model.placement(for: window) == .layout { ToolbarBar(window: window) }
        }
        context.ui.contribute(.overlay, id: "toolbar.overlay", order: 10) { window in
            ToolbarOverlay(window: window, model: model)
        }
        context.hooks.addUserScript(UserScript(source: ToolbarModel.scrollScript, injectionTime: .documentStart, mainFrameOnly: true, world: .isolated))
        context.hooks.handleMessages(named: "toolbar.scroll") { [weak self] tab, body in
            guard let self, let dir = (body as? [String: Any])?["dir"] as? Int else { return }
            self.model.pageScrolled(direction: dir, in: tab)
        }
        context.commands.handle("toolbar.toggle") { inv in
            guard let w = inv.window else { return }
            model.toggle(in: w)
        }
    }
}

@Observable
final class ToolbarModel {
    enum Placement: Equatable { case layout, overlay, hidden }

    @ObservationIgnored let runtime: BrowserRuntime
    /// Windows where the user pinned the toolbar open with ⌘⇧O.
    var forced: Set<UUID> = []

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    var mode: String { runtime.settings.string("toolbar.mode") }

    func placement(for window: BrowserWindowState) -> Placement {
        if forced.contains(window.id) || mode == "always" { return .layout }
        if mode == "never" { return .hidden }
        return window.isSidebarVisible ? .hidden : .overlay
    }

    func toggle(in window: BrowserWindowState) {
        if forced.contains(window.id) { forced.remove(window.id) } else { forced.insert(window.id) }
    }

    /// Radian "moves with you": scrolling down hides, scrolling up (or reaching the top) shows.
    func pageScrolled(direction: Int, in tab: EngineTab) {
        guard runtime.settings.bool("toolbar.hideOnScroll") else { return }
        for w in runtime.windows where runtime.selectedTab(in: w)?.engineTab === tab {
            setVisible(direction < 0, in: w)
        }
    }

    func setVisible(_ visible: Bool, in window: BrowserWindowState) {
        guard window.isToolbarVisible != visible else { return }
        withAnimation(.spring(duration: 0.32, bounce: 0.08)) { window.isToolbarVisible = visible }
        if visible { window.titlebarRequests.insert("toolbar") } else { window.titlebarRequests.remove("toolbar") }
    }

    static let scrollScript = """
    (() => {
      let last = window.scrollY, acc = 0, dir = 0;
      const post = d => { if (d !== dir) { dir = d; window.__browser && window.__browser.post('toolbar.scroll', { dir: d }); } };
      addEventListener('scroll', () => {
        const y = window.scrollY, d = y - last; last = y;
        if (y < 32) { acc = 0; post(-1); return; }
        acc = (Math.sign(d) === Math.sign(acc)) ? acc + d : d;
        if (acc > 48) post(1); else if (acc < -36) post(-1);
      }, { passive: true, capture: true });
    })();
    """
}

struct ToolbarBar: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState

    var body: some View {
        HStack(spacing: 6) {
            if !window.isSidebarVisible {
                Spacer().frame(width: 70)
                Button { try? env.runtime.commands.run("sidebar.toggle", window: window) } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show Sidebar (⌘S)")
            }
            SlotHost("toolbar.leading", window: window)
            Spacer(minLength: 8)
            SlotHost("toolbar.center", window: window).frame(maxWidth: 520)
            Spacer(minLength: 8)
            SlotHost("toolbar.trailing", window: window)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

/// When the sidebar is hidden the toolbar floats over the page and follows the scroll direction;
/// touching the top edge brings it back.
struct ToolbarOverlay: View {
    let window: BrowserWindowState
    let model: ToolbarModel
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if model.placement(for: window) == .overlay {
            VStack(spacing: 0) {
                if window.isToolbarVisible {
                    ToolbarBar(window: window)
                        .background(.regularMaterial)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onHover { inside in
                            hideTask?.cancel()
                            if !inside { scheduleHide() }
                        }
                } else {
                    Color.clear.frame(height: 6).contentShape(Rectangle())
                        .onHover { if $0 { model.setVisible(true, in: window) } }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func scheduleHide() {
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { model.setVisible(false, in: window) }
        }
    }
}
