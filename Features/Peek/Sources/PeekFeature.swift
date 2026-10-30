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
            let origin = self.clickPoint(in: window)
            DispatchQueue.main.async { model.open(action.url, in: window, from: origin) }
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

    /// Where the link was clicked, in window coordinates (top-left origin): the preview grows from there. The navigation
    /// doesn't say, but it arrives on the click, so the pointer is still on the link.
    func clickPoint(in window: BrowserWindowState) -> CGPoint? {
        guard let nsWindow = context.shell?.nsWindow(for: window) else { return nil }
        let p = nsWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = CGPoint(x: p.x, y: nsWindow.frame.height - p.y)
        return window.contentFrame.contains(point) ? point : nil
    }
}

/// The preview's page is an engine page: under CEF a child window, which can't follow an animated frame or transform
/// (AGENTS.md). So a stand-in moves, the page only ever sits still: a card grows from the link before the page shows in
/// it, and a snapshot of the page grows into the tab, or shrinks away, while the page is put away.
@Observable
final class PeekModel {
    enum Phase: Equatable {
        /// The stand-in card grows from the click; the page loads meanwhile.
        case growing
        /// The page shows in the card.
        case live
        /// Its snapshot grows to the browser's page card; then it becomes the tab.
        case expanding
        /// Its snapshot shrinks away; then the page closes.
        case closing
    }

    struct Session {
        let engineTab: EngineTab
        let sourceTabID: NodeID?
        var phase: Phase = .growing
        /// The click it grows from, in window coordinates (top-left origin); nil grows it from its center.
        var origin: CGPoint?
        var snapshot: NSImage?
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var sessions: [UUID: Session] = [:]
    var dragOffset: [UUID: CGFloat] = [:]
    /// The animations' lengths: each phase moves on by time, as SwiftUI's completions don't run in a window behind
    /// another app. Tests shorten them.
    @ObservationIgnored var growDuration: TimeInterval = 0.42
    @ObservationIgnored var expandDuration: TimeInterval = 0.38
    @ObservationIgnored var closeDuration: TimeInterval = 0.24
    /// How long a snapshot may take before the card moves without one (a heavy page can be slow to draw).
    @ObservationIgnored var snapshotTimeout: TimeInterval = 0.15

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    func session(for window: BrowserWindowState) -> Session? { sessions[window.id] }

    func open(_ url: URL, in window: BrowserWindowState, from origin: CGPoint? = nil) {
        if let existing = sessions[window.id] {
            existing.engineTab.load(url)
            return
        }
        let page = runtime.engine.makeTab(EngineTabRequest(url: url, isPrivate: window.isPrivate))
        let delegate = PeekPageDelegate(window: window, runtime: runtime)
        page.delegate = delegate
        objc_setAssociatedObject(page, &PeekPageDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        sessions[window.id] = Session(engineTab: page, sourceTabID: window.selectedTabID, origin: origin)
        after(growDuration, in: window, page: page) { [weak self] in self?.sessions[window.id]?.phase = .live }
    }

    /// Becomes a real tab (child of the tab it came from) without reloading, growing into the page's place.
    func expand(in window: BrowserWindowState) {
        guard let s = sessions[window.id], s.phase == .growing || s.phase == .live else { return }
        capture(s.engineTab) { [weak self] image in
            guard let self, self.sessions[window.id]?.engineTab === s.engineTab else { return }
            self.sessions[window.id]?.snapshot = image
            self.sessions[window.id]?.phase = .expanding  // the page leaves the card on this turn; the snapshot stands in
            self.dragOffset[window.id] = nil
            self.after(self.expandDuration, in: window, page: s.engineTab) {
                s.engineTab.delegate = nil
                let placement: NewTabPlacement = s.sourceTabID.map { .childOf($0) } ?? .automatic
                self.runtime.adopt(s.engineTab, in: window, placement: placement)
                // The tab's page is under the snapshot now: it goes on the next turn, so nothing flashes between them.
                DispatchQueue.main.async { self.sessions[window.id] = nil }
            }
        }
    }

    func close(in window: BrowserWindowState) {
        guard let s = sessions[window.id], s.phase != .closing, s.phase != .expanding else { return }
        capture(s.engineTab) { [weak self] image in
            guard let self, self.sessions[window.id]?.engineTab === s.engineTab else { return }
            self.sessions[window.id]?.snapshot = image
            self.sessions[window.id]?.phase = .closing
            self.after(self.closeDuration, in: window, page: s.engineTab) {
                self.sessions[window.id] = nil
                self.dragOffset[window.id] = nil
                s.engineTab.close()
            }
        }
    }

    /// The page's snapshot, or nil once `snapshotTimeout` passed.
    private func capture(_ page: EngineTab, _ then: @escaping (NSImage?) -> Void) {
        var done = false
        let finish = { (image: NSImage?) in
            guard !done else { return }
            done = true
            then(image)
        }
        page.snapshot(maxWidth: 2400) { image in
            if Thread.isMainThread { finish(image) } else { DispatchQueue.main.async { finish(image) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + snapshotTimeout) { finish(nil) }
    }

    /// Runs `step` after `delay` if the same page still previews in the window.
    private func after(_ delay: TimeInterval, in window: BrowserWindowState, page: EngineTab, _ step: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.sessions[window.id]?.engineTab === page else { return }
            step()
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: PeekModel

    var body: some View {
        GeometryReader { geo in
            if let session = model.session(for: window) {
                PeekCard(window: window, model: model, session: session, bounds: geo.size, reduceMotion: reduceMotion)
                    .onKeyPress(.escape) { model.close(in: window); return .handled }
            }
        }
    }
}

/// The preview card in each phase (`PeekModel.Phase`): the stand-in grows from the click, then the page shows; a
/// snapshot grows to the page card (expand) or shrinks away (close).
struct PeekCard: View {
    let window: BrowserWindowState
    let model: PeekModel
    let session: PeekModel.Session
    let bounds: CGSize
    let reduceMotion: Bool
    /// Off until the card's first frame, so it grows from where it starts.
    @State private var arrived = false

    static let toolbarHeight: CGFloat = 38
    static let radius: CGFloat = 14

    var body: some View {
        let drag = model.dragOffset[window.id] ?? 0
        let card = Self.frame(in: bounds, content: window.contentFrame)
        let expanding = session.phase == .expanding
        let closing = session.phase == .closing
        let target = expanding && window.contentFrame != .zero ? window.contentFrame : card
        ZStack(alignment: .topLeading) {
            Color.black.opacity(expanding || closing || !arrived ? 0 : 0.22 * (1 - min(1, drag / 400)))
                .contentShape(Rectangle())
                .onTapGesture { model.close(in: window) }
            VStack(spacing: 0) {
                PeekToolbar(window: window, model: model, state: session.engineTab.state)
                    .frame(height: expanding ? 0 : Self.toolbarHeight, alignment: .bottom)
                    .opacity(expanding ? 0 : 1)
                    .clipped()
                page
            }
            .frame(width: target.width, height: target.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: expanding ? window.cardRadius : Self.radius, style: .continuous))
            .shadow(color: .black.opacity(expanding ? 0 : 0.35), radius: 30, y: 12)
            .scaleEffect(scale, anchor: .center)
            .offset(offset(card: card))
            .opacity(arrived && !closing ? 1 : 0)
            .offset(y: session.phase == .live ? max(0, drag) : 0)
            // Placed by layout, not an offset: the page's view (a child window under CEF) goes where the card is.
            .padding(.leading, target.minX)
            .padding(.top, target.minY)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .animation(animation, value: session.phase)
        .animation(animation, value: arrived)
        .onAppear { DispatchQueue.main.async { arrived = true } }
    }

    /// The live page only while the card stands still; its snapshot (or the bare card) while it moves.
    @ViewBuilder private var page: some View {
        if session.phase == .live {
            PeekContent(engineTab: session.engineTab, runtime: model.runtime)
        } else if let snapshot = session.snapshot {
            // Pinned top-left as the page lays out, so a change of width crops its end, not its start.
            Image(nsImage: snapshot).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    /// Small at the click, full size once arrived; a little smaller as it closes.
    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if session.phase == .closing { return 0.94 }
        return arrived ? 1 : 0.12
    }

    /// From the click to the card's place (its center, before it arrives); down a little as it closes.
    private func offset(card: CGRect) -> CGSize {
        if reduceMotion { return .zero }
        if session.phase == .closing { return CGSize(width: 0, height: 24) }
        guard !arrived, let origin = session.origin else { return .zero }
        return CGSize(width: origin.x - card.midX, height: origin.y - card.midY)
    }

    private var animation: Animation {
        if reduceMotion { return Design.Motion.reduced }
        switch session.phase {
        case .growing: return Design.Motion.grow
        case .live: return Design.Motion.grow
        case .expanding: return Design.Motion.expand
        case .closing: return Design.Motion.leave
        }
    }

    /// The card at rest: inside the page card (so becoming the tab grows it), a little in from its sides and top, as
    /// Arc's; centered in the window when there's no page card yet.
    static func frame(in bounds: CGSize, content: CGRect) -> CGRect {
        guard content.width > 200, content.height > 200 else {
            let width = min(bounds.width - 120, 1100), height = bounds.height - 70
            return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2 + 20, width: width, height: height)
        }
        let side = min(56, content.width * 0.06)
        let width = min(content.width - side * 2, 1100)
        return CGRect(x: content.midX - width / 2, y: content.minY + 28, width: width, height: content.height - 28 - 12)
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
