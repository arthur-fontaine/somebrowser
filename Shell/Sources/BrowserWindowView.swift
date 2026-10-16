import AppKit
import BrowserCore
import SwiftUI

/// Window layout made only of slots: background, sidebar, toolbar, web content, overlays.
/// Which feature fills a slot is decided by the generated registry, never here.
struct BrowserWindowView: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    /// Engines with page child windows get overlays from `OverlayLayer` in a separate window.
    var overlaysInline = true

    var body: some View {
        let ui = env.runtime.ui
        ZStack(alignment: .topLeading) {
            background(ui)
            HStack(spacing: 0) {
                // The page is a window of its own under some engines: its frame changes once, never animated. The sidebar
                // animates its own arrival inside this column.
                let docked = (window.isSidebarVisible || window.isSidebarLeaving) && !ui.views(for: .sidebar).isEmpty
                if docked {
                    SlotHost(.sidebar, window: window)
                        .frame(width: window.sidebarWidth)
                }
                VStack(spacing: 0) {
                    SlotHost(.toolbar, window: window)
                    HStack(spacing: 0) {
                        content
                        SlotHost(.contentTrailing, window: window)
                    }
                }
                .padding([.top, .bottom, .trailing], Design.windowInset)
                .padding(.leading, docked ? 0 : Design.windowInset)
            }
            if overlaysInline { SlotHost(.overlay, window: window) }
        }
        .ignoresSafeArea()
        // SwiftUI would draw the sidebar inactive whenever the page (a window of its own under Chromium) has focus.
        .environment(\.controlActiveState, window.isKeyWindow ? .key : .inactive)
        .onChange(of: window.isSidebarVisible || window.isSidebarLeaving) { env.runtime.shell?.contentLayoutDidChange(in: window) }
    }

    @ViewBuilder
    private func background(_ ui: UIRegistry) -> some View {
        if ui.views(for: "background").isEmpty {
            VisualEffectBackground(material: .underWindowBackground)
        } else {
            SlotHost("background", window: window)
        }
    }

    private var content: some View {
        let runtime = env.runtime
        let selected = runtime.selectedTab(in: window)
        let showsEmpty = selected == nil || (selected?.url == nil && selected?.isLoaded == false)
        return ZStack {
            ContentArea(window: window, runtime: runtime)
            if showsEmpty {
                ZStack { SlotHost(.emptyContent, window: window) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
            if overlaysInline { SlotHost(.contentOverlay, window: window) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material }
}

/// Hosts the engine viewport. AppKit clipping (layer corner radius) keeps web content inside the rounded
/// content shape, which SwiftUI clipping cannot do for NSView subviews.
struct ContentArea: NSViewRepresentable {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    func makeNSView(context: Context) -> ContentContainerView {
        let v = ContentContainerView()
        v.onAttach = { [weak window, weak runtime] view in
            guard let window, let runtime, view.viewport == nil else { return }
            let viewport = runtime.engine.makeViewport(in: view)
            view.viewport = viewport  // the container owns its viewport; the window state only references it
            window.viewport = viewport
            if let tab = runtime.selectedTab(in: window), tab.url != nil || tab.isLoaded {
                viewport.present(runtime.live(tab))
            }
        }
        v.onLayout = { [weak window, weak v] in
            guard let window, let v else { return }
            window.viewport?.layoutDidChange()
            if let host = v.window?.contentView {
                let r = v.convert(v.bounds, to: host)
                let frame = CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
                if window.contentFrame != frame { window.contentFrame = frame }
            }
        }
        return v
    }

    func updateNSView(_ nsView: ContentContainerView, context: Context) {}
}

final class ContentContainerView: NSView {
    var onAttach: ((ContentContainerView) -> Void)?
    var viewport: EngineViewport?
    var onLayout: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.cardRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?(self) }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
