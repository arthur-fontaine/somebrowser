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
        /// It's the tab: the snapshot over it fades away.
        case landed
        /// Its snapshot shrinks away; then the page closes.
        case closing
    }

    struct Session {
        let engineTab: EngineTab
        let sourceTabID: NodeID?
        /// What it previews, for the stand-in (favicon and host) before the page says.
        let url: URL
        var phase: Phase = .growing
        /// The page put away while the card still stands: the snapshot under it shows, and the card moves a frame later,
        /// once the page's window is surely gone (it lingered for a frame, a ghost over the moving card).
        var hidesPage = false
        /// The click it grows from, in window coordinates (top-left origin); nil grows it from its center.
        var origin: CGPoint?
        var snapshot: NSImage?
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var sessions: [UUID: Session] = [:]
    var dragOffset: [UUID: CGFloat] = [:]
    /// The animations' lengths: each phase moves on by time, as SwiftUI's completions don't run in a window behind
    /// another app. Tests shorten them.
    @ObservationIgnored var growDuration = Design.Motion.growDuration
    /// Less than the curve's length: it has visibly landed by then (it starts fast), and the snapshot fades over the tab.
    @ObservationIgnored var expandDuration = Design.Motion.expandDuration * 0.75
    @ObservationIgnored var closeDuration = Design.Motion.leaveDuration
    @ObservationIgnored var fadeDuration: TimeInterval = 0.12
    /// Between putting the page away and moving the card.
    @ObservationIgnored var hideDelay: TimeInterval = 0.03
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
        sessions[window.id] = Session(engineTab: page, sourceTabID: window.selectedTabID, url: url, origin: origin)
        after(growDuration, in: window, page: page) { [weak self] in
            // Unless it was expanded or closed while growing.
            if self?.sessions[window.id]?.phase == .growing { self?.sessions[window.id]?.phase = .live }
        }
    }

    /// Becomes a real tab (child of the tab it came from) without reloading, growing into the page's place.
    func expand(in window: BrowserWindowState) {
        guard let s = sessions[window.id], s.phase == .growing || s.phase == .live else { return }
        putAway(s, in: window, then: .expanding) {
            s.engineTab.delegate = nil
            let placement: NewTabPlacement = s.sourceTabID.map { .childOf($0) } ?? .automatic
            self.runtime.adopt(s.engineTab, in: window, placement: placement)
            // The tab's page is under the snapshot now: the snapshot fades off it.
            self.sessions[window.id]?.phase = .landed
            self.after(self.fadeDuration, in: window, page: s.engineTab) { self.sessions[window.id] = nil }
        }
    }

    func close(in window: BrowserWindowState) {
        guard let s = sessions[window.id], s.phase == .growing || s.phase == .live else { return }
        putAway(s, in: window, then: .closing) {
            self.sessions[window.id] = nil
            self.dragOffset[window.id] = nil
            s.engineTab.close()
        }
    }

    /// Snapshot, page away, then `phase` (the card moves), then `done` once it has moved.
    private func putAway(_ s: Session, in window: BrowserWindowState, then phase: Phase, done: @escaping () -> Void) {
        capture(s.engineTab) { [weak self] image in
            guard let self, self.sessions[window.id]?.engineTab === s.engineTab else { return }
            self.sessions[window.id]?.snapshot = image
            self.sessions[window.id]?.hidesPage = true
            self.after(self.hideDelay, in: window, page: s.engineTab) {
                self.sessions[window.id]?.phase = phase
                self.dragOffset[window.id] = nil
                self.after(phase == .closing ? self.closeDuration : self.expandDuration, in: window, page: s.engineTab, done)
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

/// The preview in each phase (`PeekModel.Phase`): the page in a Liquid Glass container (the app's floating panels'),
/// under a row of floating controls (Safari's iOS bar, on a Mac). The stand-in grows from the click, then the page shows; a snapshot grows to the
/// page card (expand) or shrinks away (close).
struct PeekCard: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: PeekModel
    let session: PeekModel.Session
    let bounds: CGSize
    let reduceMotion: Bool
    /// Off until the card's first frame, so it grows from where it starts.
    @State private var arrived = false

    /// The row's height and its gap to the container.
    static let rowSpace = Design.Size.control + Design.Space.divider
    /// The glass around the page, and the page's corners concentric inside it.
    static let rim = Design.Space.block
    static let pageRadius = Design.concentric(Design.Radius.panel, inset: rim)

    var body: some View {
        let drag = model.dragOffset[window.id] ?? 0
        let card = Self.frame(in: bounds, content: window.contentFrame)
        let phase = session.phase
        let full = phase == .expanding || phase == .landed  // in the page card's place
        let target = full && window.contentFrame != .zero ? window.contentFrame : card
        let rowShown = phase == .live
        ZStack(alignment: .topLeading) {
            Design.Fill.scrim
                .opacity(phase == .growing || phase == .live ? (arrived ? 1 - min(1, drag / 400) : 0) : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.close(in: window) }
            PeekControls(window: window, model: model, session: session)
                .frame(width: card.width)
                .opacity(rowShown ? 1 : 0)
                .scaleEffect(rowShown || reduceMotion ? 1 : Design.Motion.panelEnterScale)
                .offset(y: full && !reduceMotion ? -Design.Space.block : 0)
                .offset(y: phase == .live ? max(0, drag) : 0)
                .animation(reduceMotion ? Design.Motion.reduced : rowShown ? Design.Motion.panelSettle : Design.Motion.panelExit,
                           value: rowShown)
                .padding(.leading, card.minX)
                .padding(.top, card.minY - Self.rowSpace)
            page
                .clipShape(RoundedRectangle(cornerRadius: full ? window.cardRadius : Self.pageRadius, style: .continuous))
                .opacity(phase == .landed ? 0 : 1)
                // Growing into the tab, the rim closes and the glass takes the page card's corners on the same curve; it
                // fades off the tab with the snapshot.
                .padding(full ? 0 : Self.rim)
                .frame(width: target.width, height: target.height)
                .background {
                    Color.clear
                        .glassSurface(in: RoundedRectangle(cornerRadius: full ? window.cardRadius : Design.Radius.panel, style: .continuous))
                        .opacity(phase == .landed ? 0 : 1)
                }
                .scaleEffect(scale, anchor: .center)
                .offset(offset(card: card))
                .opacity(arrived && phase != .closing ? 1 : 0)
                .offset(y: phase == .live ? max(0, drag) : 0)
                // Placed by layout, not an offset: the page's view (a child window under CEF) goes where the card is.
                .padding(.leading, target.minX)
                .padding(.top, target.minY)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .animation(animation, value: session.phase)
        .animation(animation, value: arrived)
        .onAppear { DispatchQueue.main.async { arrived = true } }
    }

    /// The live page only while the card stands still, over its snapshot (shown once the page is put away); the
    /// snapshot, or the stand-in, while the card moves.
    @ViewBuilder private var page: some View {
        ZStack {
            still
            if session.phase == .live {
                PeekContent(engineTab: session.engineTab, runtime: model.runtime, isShown: !session.hidesPage, cornerRadius: Self.pageRadius)
            }
        }
    }

    /// The page as a picture: its snapshot at its own size, pinned top-left as the page lays out (so the tab's page lands
    /// where it was), or the site's icon and name while it loads, as Arc's preview does.
    @ViewBuilder private var still: some View {
        if let snapshot = session.snapshot {
            Image(nsImage: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: Self.bottomColor(of: snapshot) ?? .white))
                .clipped()
        } else {
            // White, as pages are (in Dark too: a dark card then a white page flashed on every open).
            VStack(spacing: Design.Space.block) {
                SiteIcon(env.runtime.favicons.image(for: session.url)).frame(width: 32, height: 32)
                Text(PeekControls.site(session.url)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
    }

    /// The page's colour at its bottom edge: what continues it as the card grows taller than the snapshot.
    static func bottomColor(of image: NSImage) -> NSColor? {
        guard let rep = image.representations.first as? NSBitmapImageRep ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(NSBitmapImageRep.init(cgImage:)), rep.pixelsHigh > 1 else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 1)
    }

    /// Small at the click, full size once arrived; a little smaller as it closes.
    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if session.phase == .closing { return Design.Motion.panelExitScale }
        return arrived ? 1 : 0.12
    }

    /// From the click to the card's place (its center, before it arrives).
    private func offset(card: CGRect) -> CGSize {
        guard !reduceMotion, !arrived, let origin = session.origin else { return .zero }
        return CGSize(width: origin.x - card.midX, height: origin.y - card.midY)
    }

    private var animation: Animation {
        if reduceMotion { return Design.Motion.reduced }
        switch session.phase {
        case .growing, .live: return Design.Motion.grow
        case .expanding: return Design.Motion.expand
        case .landed: return Design.Motion.panelExit
        case .closing: return Design.Motion.leave
        }
    }

    /// The container at rest: inside the browser's page card (so becoming the tab grows it), a tile gutter in from its
    /// sides and bottom, under the row (the same in the window when there's no page card yet). The row sits below the
    /// header, level with the sidebar's address field, clear of the traffic lights.
    static func frame(in bounds: CGSize, content: CGRect) -> CGRect {
        let area = content.width > 200 && content.height > 200 ? content : CGRect(origin: .zero, size: bounds)
        let inset = Design.Space.tileGutter
        let top = max(area.minY + inset, Design.Size.header) + rowSpace
        let width = min(area.width - inset * 2, 1100)
        return CGRect(x: area.midX - width / 2, y: top, width: width, height: area.maxY - inset - top)
    }
}

/// The controls above the page: glass pieces in one group, the site's title centered, Open as Tab in words and × as a
/// circle at the end. The title is a label, not a field: the site's icon and host, hugging them. Drag the row down to put the
/// preview away.
struct PeekControls: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: PeekModel
    let session: PeekModel.Session
    /// The buttons' width at the end: the title keeps as clear of each side, so it stays centered on the page.
    @State private var trailingWidth: CGFloat = 0

    var body: some View {
        let state = session.engineTab.state
        let shown = state.url ?? session.url
        let openHelp = env.runtime.commands.shortcut(for: "peek.expand").map { "Open as Tab (\($0.displayString))" } ?? "Open as Tab"
        GlassGroup(spacing: Design.Space.block) {
            ZStack {
                HStack(spacing: Design.Space.block) {
                    Spacer(minLength: 0)
                    trailing(openHelp: openHelp)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                }
                HStack(spacing: Design.Grid.iconToText) {
                    SiteIcon(state.favicon ?? env.runtime.favicons.image(for: shown))
                        .frame(width: Design.Size.favicon, height: Design.Size.favicon)
                    Text(Self.site(shown)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, Design.Grid.iconInset)
                .padding(.trailing, Design.Space.capsuleTrailing)
                .frame(height: Design.Size.control)
                .glassSurface(in: Capsule())  // a label: glass that doesn't answer the pointer
                .help(shown.absoluteString)
                // Centered on the page, clear of the buttons on both sides.
                .padding(.horizontal, trailingWidth + Design.Space.block)
            }
        }
        .frame(height: Design.Size.control)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4).onChanged { v in
            model.dragOffset[window.id] = max(0, v.translation.height)
        }.onEnded { v in
            // Dragged down far or fast enough, the preview goes; else it springs back.
            if v.translation.height > 140 || v.predictedEndTranslation.height > 400 {
                model.close(in: window)
            } else {
                withAnimation(Design.Motion.toast) { model.dragOffset[window.id] = 0 }
            }
        })
    }

    /// The primary action in words, as a Mac's are (Quick Look's Open with…); × stays a circle.
    private func trailing(openHelp: String) -> some View {
        HStack(spacing: Design.Space.block) {
            Button { model.expand(in: window) } label: {
                Text("Open as Tab").font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, Design.Space.capsuleTrailing)
                    .frame(height: Design.Size.control)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassControl(in: Capsule())
            .help(openHelp)
            ChromeButton(systemImage: "xmark", help: "Close") { model.close(in: window) }
        }
    }

    /// The host without `www.`.
    static func site(_ url: URL?) -> String {
        var host = url?.host() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// A second engine viewport, inside the preview card.
struct PeekContent: NSViewRepresentable {
    let engineTab: EngineTab
    let runtime: BrowserRuntime
    /// False puts the page away (the card is about to move) while the view stays.
    var isShown = true
    /// The page's corners: engines round its window to its container's layer (CEF's is a child window, which a SwiftUI
    /// clip can't round; left unset it took the page card's, a dark sliver in each corner of the glass).
    var cornerRadius: CGFloat

    final class Container: NSView {
        var viewport: EngineViewport?
        var isShown = true
        override func layout() { super.layout(); viewport?.layoutDidChange() }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.isShown = isShown
        DispatchQueue.main.async {
            let viewport = runtime.engine.makeViewport(in: v)
            v.viewport = viewport
            viewport.present(v.isShown ? engineTab : nil)
        }
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        v.isShown = isShown
        let wanted: EngineTab? = isShown ? engineTab : nil
        if let viewport = v.viewport, viewport.presentedTab !== wanted { viewport.present(wanted) }
    }

    static func dismantleNSView(_ v: Container, coordinator: ()) {
        v.viewport?.tearDown()
    }
}
