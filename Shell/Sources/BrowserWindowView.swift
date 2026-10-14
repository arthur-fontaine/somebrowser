import AppKit
import BrowserCore
import SwiftUI

/// Window layout made only of slots: background, sidebar, toolbar, web content, overlays.
/// Which feature fills a slot is decided by the generated registry, never here.
struct BrowserWindowView: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState

    static let contentInset: CGFloat = 6
    static let contentCornerRadius: CGFloat = 10

    var body: some View {
        let ui = env.runtime.ui
        ZStack(alignment: .topLeading) {
            background(ui)
            HStack(spacing: 0) {
                if window.isSidebarVisible && !ui.views(for: .sidebar).isEmpty {
                    SlotHost(.sidebar, window: window)
                        .frame(width: window.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    SlotHost(.toolbar, window: window)
                    content
                }
                .padding([.top, .bottom, .trailing], Self.contentInset)
                .padding(.leading, window.isSidebarVisible ? 0 : Self.contentInset)
            }
            SlotHost(.overlay, window: window)
        }
        .ignoresSafeArea()
        .animation(.spring(duration: 0.32, bounce: 0.12), value: window.isSidebarVisible)
        .onChange(of: window.isSidebarVisible) { env.runtime.shell?.contentLayoutDidChange(in: window) }
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
            SlotHost(.contentOverlay, window: window)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.contentCornerRadius, style: .continuous))
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
            guard let window, let runtime, window.viewport == nil else { return }
            let viewport = runtime.engine.makeViewport(in: view)
            window.viewport = viewport
            if let tab = runtime.selectedTab(in: window), tab.url != nil || tab.isLoaded {
                viewport.present(runtime.live(tab))
            }
        }
        v.onLayout = { [weak window] in window?.viewport?.layoutDidChange() }
        return v
    }

    func updateNSView(_ nsView: ContentContainerView, context: Context) {}
}

final class ContentContainerView: NSView {
    var onAttach: ((NSView) -> Void)?
    var onLayout: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = BrowserWindowView.contentCornerRadius
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
