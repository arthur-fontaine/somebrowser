import AppKit
import BrowserCore
import SwiftUI

public final class PeekFeature: BrowserFeature {
    let context: FeatureContext
    let model: PeekModel

    public init(context: FeatureContext) {
        self.context = context
        model = PeekModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        context.hooks.addNavigationPolicy { [weak self] action in
            guard let self, let window = self.shouldPeek(action) else { return .allow }
            DispatchQueue.main.async { model.open(action.url, in: window) }
            return .handled
        }
        context.commands.handle("peek.expand", isEnabled: { inv in inv.window.map { model.session(for: $0) != nil } ?? false }) { inv in
            if let w = inv.window { model.expand(in: w) }
        }
        context.commands.handle("peek.close", isEnabled: { inv in inv.window.map { model.session(for: $0) != nil } ?? false }) { inv in
            if let w = inv.window { model.close(in: w) }
        }
        context.ui.contribute(.overlay, id: "peek", order: 90) { window in PeekOverlay(window: window, model: model) }
    }

    /// Links from pinned tabs/favorites to another site, or ⇧-clicks, go to the preview.
    func shouldPeek(_ action: NavigationAction) -> BrowserWindowState? {
        guard action.isMainFrame, action.userGesture, let source = action.sourceTab,
              let tab = context.tabs.allTabs.first(where: { $0.engineTab === source }),
              let window = context.windows.first(where: { $0.selectedTabID == tab.id }),
              model.session(for: window)?.engineTab !== source else { return nil }
        if action.modifiers.contains(.shift) && context.settings.bool("peek.shiftClick") { return window }
        guard context.settings.bool("peek.fromPinned"), context.tabs.isPinned(tab.id) || context.tabs.isFavorite(tab.id) else { return nil }
        let from = SiteSettingsStore.site(for: source.state.url), to = SiteSettingsStore.site(for: action.url)
        return from != nil && from != to ? window : nil
    }
}

@Observable
final class PeekModel {
    struct Session {
        let engineTab: EngineTab
        let sourceTabID: NodeID?
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var sessions: [UUID: Session] = [:]
    var dragOffset: [UUID: CGFloat] = [:]

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    func session(for window: BrowserWindowState) -> Session? { sessions[window.id] }

    func open(_ url: URL, in window: BrowserWindowState) {
        if let existing = sessions[window.id] {
            existing.engineTab.load(url)
            return
        }
        let page = runtime.engine.makeTab(EngineTabRequest(url: url, isPrivate: window.isPrivate))
        let delegate = PeekPageDelegate(window: window, runtime: runtime)
        page.delegate = delegate
        objc_setAssociatedObject(page, &PeekPageDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        withAnimation(.spring(duration: 0.42, bounce: 0.18)) {
            sessions[window.id] = Session(engineTab: page, sourceTabID: window.selectedTabID)
        }
    }

    /// Becomes a real tab (child of the tab it came from) without reloading.
    func expand(in window: BrowserWindowState) {
        guard let s = sessions.removeValue(forKey: window.id) else { return }
        s.engineTab.delegate = nil
        let placement: NewTabPlacement = s.sourceTabID.map { .childOf($0) } ?? .automatic
        runtime.adopt(s.engineTab, in: window, placement: placement)
    }

    func close(in window: BrowserWindowState) {
        guard let s = sessions[window.id] else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.05)) { sessions[window.id] = nil }
        dragOffset[window.id] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { s.engineTab.close() }
    }
}

/// Popups from inside a preview become regular tabs.
final class PeekPageDelegate: EngineTabDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    weak var window: BrowserWindowState?
    weak var runtime: BrowserRuntime?

    init(window: BrowserWindowState, runtime: BrowserRuntime) {
        self.window = window
        self.runtime = runtime
    }

    func engineTab(_ tab: EngineTab, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, userGesture: Bool) {
        guard let window, let runtime else { newTab.close(); return }
        runtime.adopt(newTab, in: window, select: disposition != .backgroundTab)
    }
}

struct PeekOverlay: View {
    let window: BrowserWindowState
    let model: PeekModel

    var body: some View {
        if let session = model.session(for: window) {
            let drag = model.dragOffset[window.id] ?? 0
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.22 * (1 - min(1, drag / 400)))
                        .contentShape(Rectangle())
                        .onTapGesture { model.close(in: window) }
                    VStack(spacing: 0) {
                        PeekToolbar(window: window, model: model, state: session.engineTab.state)
                        PeekContent(engineTab: session.engineTab, runtime: model.runtime)
                    }
                    .frame(width: min(geo.size.width - 120, 1100), height: geo.size.height - 70)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    .offset(y: max(0, drag) + 20)
                    .scaleEffect(1 - min(0.08, drag / 4000))
                }
            }
            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .move(edge: .bottom).combined(with: .opacity)))
            .onKeyPress(.escape) { model.close(in: window); return .handled }
        }
    }
}

struct PeekToolbar: View {
    let window: BrowserWindowState
    let model: PeekModel
    let state: EngineTabState

    var body: some View {
        HStack(spacing: 10) {
            Button { model.close(in: window) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.borderless).help("Close (Esc)")
            Text(state.title.isEmpty ? (state.url?.host() ?? "") : state.title)
                .font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Capsule().fill(.quaternary).frame(width: 36, height: 4).offset(y: -12) }
            Button { model.expand(in: window) } label: {
                Label("Open as Tab", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless).help("Open as Tab (⌘O)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4).onChanged { v in
            model.dragOffset[window.id] = max(0, v.translation.height)
        }.onEnded { v in
            if v.translation.height > 140 || v.predictedEndTranslation.height > 400 {
                model.close(in: window)
            } else {
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) { model.dragOffset[window.id] = 0 }
            }
        })
    }
}

/// A second engine viewport, inside the preview card.
struct PeekContent: NSViewRepresentable {
    let engineTab: EngineTab
    let runtime: BrowserRuntime

    final class Container: NSView {
        var viewport: EngineViewport?
        override func layout() { super.layout(); viewport?.layoutDidChange() }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.wantsLayer = true
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
