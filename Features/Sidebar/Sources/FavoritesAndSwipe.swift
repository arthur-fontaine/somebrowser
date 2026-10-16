import AppKit
import BrowserCore
import SwiftUI

/// Arc/Radian favorites: a grid of icon tiles above the space, shared across spaces.
struct FavoritesGrid: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel
    @State private var targeted = false

    var body: some View {
        let store = env.runtime.tabs
        let ids = store.favorites
        if !ids.isEmpty || model.dragging != nil {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 120), spacing: 6)], spacing: 6) {
                ForEach(ids, id: \.self) { id in
                    if let tab = store.tab(id) { FavoriteTile(tab: tab, window: window) }
                }
            }
            .frame(minHeight: ids.isEmpty ? Design.Size.tile : 0)
            .background {
                if ids.isEmpty {
                    Design.itemShape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .overlay(Text("Drop to add a favorite").font(.system(size: 11)).foregroundStyle(.tertiary))
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { _ = env.runtime.sidebarHistory.move(id) { SidebarLogic.drop(id, into: .favorites, store: store) } }
                return true
            } isTargeted: { targeted = $0 }
            .animation(.spring(duration: 0.35, bounce: 0.2), value: ids)
        }
    }
}

struct FavoriteTile: View {
    @Environment(BrowserEnvironment.self) private var env
    let tab: BrowserTab
    let window: BrowserWindowState
    @State private var hovering = false

    var body: some View {
        let selected = window.selectedTabID == tab.id
        FaviconView(tab: tab)
            .frame(width: 18, height: 18)
            .frame(maxWidth: .infinity, minHeight: Design.Size.tile)
            // Tiles are washes, like rows; the open one gets the selection's lens.
            .background { if !selected { Design.itemShape.fill(hovering ? Design.Fill.selection : Design.Fill.tile) } }
            .modifier(TileLens(selected: selected))
            .overlay(alignment: .bottom) {
                if tab.live?.isPlayingAudio == true {
                    Image(systemName: "music.note").font(.system(size: 8)).foregroundStyle(.secondary)
                        .symbolEffect(.bounce, options: .repeating).padding(.bottom, 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(tab.displayTitle)
            .onTapGesture {
                // Clicking the selected favorite's icon resets it to its pinned URL (Arc).
                if selected, tab.hasNavigatedAwayFromPin, let home = tab.pinnedURL {
                    env.runtime.navigate(tab, to: home)
                } else {
                    env.runtime.select(tab.id, in: window)
                }
            }
            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
            .contextMenu {
                Button("Remove from Favorites") { env.runtime.sidebarHistory.move(tab.id) { env.runtime.tabs.unpin(tab.id, in: window.spaceID) } }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((tab.live?.url ?? tab.url)?.absoluteString ?? "", forType: .string)
                }
                Button("Close") { env.runtime.sidebarHistory.close([tab.id], includingDescendants: false) }
            }
    }
}

/// The open favorite: the same glass as the selected row's lens (a wash in solid style or on glass).
struct TileLens: ViewModifier {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.isOnGlass) private var isOnGlass
    let selected: Bool

    func body(content: Content) -> some View {
        let solid = env.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.solid.rawValue
        if !selected {
            content
        } else if solid || isOnGlass {
            content.background(Design.itemShape.fill(Design.Fill.selection))
        } else {
            content.glassSurface(in: Design.itemShape)
        }
    }
}

/// Two-finger horizontal swipes over the sidebar page between spaces (Arc, Radian). The content tracks
/// the fingers; release decides with a spring.
struct SwipeCatcher: NSViewRepresentable {
    let window: BrowserWindowState
    let model: SidebarModel
    let width: CGFloat
    let runtime: BrowserRuntime

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        v.onSwipe = { phase, delta in handle(phase, delta) }
        return v
    }

    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.onSwipe = { phase, delta in handle(phase, delta) }
        nsView.enabled = runtime.settings.bool("sidebar.swipeBetweenSpaces")
    }

    private func handle(_ phase: SwipeView.Phase, _ delta: CGFloat) {
        let spaces = runtime.tabs.spaces
        guard let i = spaces.firstIndex(where: { $0.id == window.spaceID }) else { return }
        var offset = model.swipeOffset[window.id] ?? 0
        switch phase {
        case .changed:
            offset += delta
            let hasNeighbor = offset < 0 ? i + 1 < spaces.count : i > 0
            model.swipeOffset[window.id] = hasNeighbor ? offset : offset * 0.35
        case .ended(let velocity):
            let threshold = width * 0.22
            let goNext = offset < -threshold || velocity < -600
            let goPrev = offset > threshold || velocity > 600
            if goNext, i + 1 < spaces.count {
                finish(to: spaces[i + 1].id, sign: -1)
            } else if goPrev, i > 0 {
                finish(to: spaces[i - 1].id, sign: 1)
            } else {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { model.swipeOffset[window.id] = 0 }
            }
        }
    }

    private func finish(to space: UUID, sign: CGFloat) {
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            model.swipeOffset[window.id] = sign * width
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                runtime.switchSpace(space, in: window)
                model.swipeOffset[window.id] = 0
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}

final class SwipeView: NSView {
    enum Phase { case changed, ended(velocity: CGFloat) }
    var onSwipe: ((Phase, CGFloat) -> Void)?
    var enabled = true
    private var monitor: Any?
    private var tracking = false
    private var samples: [(t: TimeInterval, dx: CGFloat)] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.handle(e) ?? e }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard enabled, e.window === window, e.hasPreciseScrollingDeltas else { return e }
        if e.phase == .began {
            let p = convert(e.locationInWindow, from: nil)
            tracking = bounds.contains(p) && abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY)
            samples = []
        }
        guard tracking else { return e }
        if !e.momentumPhase.isEmpty { return nil }  // our spring replaces the system momentum
        switch e.phase {
        case .changed, .began:
            samples.append((e.timestamp, e.scrollingDeltaX))
            if samples.count > 6 { samples.removeFirst() }
            onSwipe?(.changed, e.scrollingDeltaX)
            return nil
        case .ended, .cancelled:
            tracking = false
            let dt = (samples.last?.t ?? 0) - (samples.first?.t ?? 0)
            let v = dt > 0 ? samples.map(\.dx).reduce(0, +) / CGFloat(dt) : 0
            onSwipe?(.ended(velocity: v), 0)
            return nil
        default:
            return e
        }
    }
}
