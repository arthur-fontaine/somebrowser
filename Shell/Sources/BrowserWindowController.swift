import AppKit
import BrowserCore
import SwiftUI

/// The browser window: a real NSWindow we own (native titlebar behaviour, full-size content,
/// traffic lights inside the sidebar like Arc). Its whole content is a SwiftUI tree made of slots.
final class ShellWindow: NSWindow {
    /// Engines that put pages in child windows (CEF) report the page window here so the shell keeps
    /// its active appearance (traffic lights, sidebar vibrancy) while the page has keyboard focus.
    var childKeyWindowProvider: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @objc var _hasActiveAppearance: Bool {
        isKeyWindow || childKeyWindowProvider?() == true
    }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let state: BrowserWindowState
    private let runtime: BrowserRuntime
    private weak var shell: ShellController?
    private var hosting: NSHostingView<AnyView>?
    private var overlay: OverlayWindow?

    init(state: BrowserWindowState, runtime: BrowserRuntime, shell: ShellController) {
        self.state = state
        self.runtime = runtime
        self.shell = shell
        let frame = state.frameDescriptor.map(NSRectFromString) ?? Self.defaultFrame()
        let window = ShellWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.backgroundColor = .clear
        window.isOpaque = false
        window.title = state.isPrivate ? "Private" : Brand.name
        if state.frameDescriptor == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        let childWindows = runtime.engine.capabilities.contains(.childWindowContent)
        let root = BrowserWindowView(window: state, overlaysInline: !childWindows)
            .environment(BrowserEnvironment(runtime: runtime))
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        window.contentView = hosting
        self.hosting = hosting
        // Keep the shell looking active while a page or overlay child window has keyboard focus.
        window.childKeyWindowProvider = { [weak window] in window?.childWindows?.contains { $0.isKeyWindow } ?? false }
        if childWindows {
            let overlay = OverlayWindow(state: state, runtime: runtime)
            self.overlay = overlay
            window.addChildWindow(overlay, ordered: .above)
            layoutOverlay()
        }
        observeChrome()
    }

    /// Arc hides the traffic lights with the sidebar; they come back when something needs the titlebar.
    private func observeChrome() {
        withObservationTracking {
            _ = state.isSidebarVisible
            _ = state.isSidebarPeeking
            _ = state.titlebarRequests
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateTrafficLights()
                self?.observeChrome()
            }
        }
        updateTrafficLights()
    }

    private func updateTrafficLights() {
        let hasSidebar = !runtime.ui.views(for: .sidebar).isEmpty
        let visible = !hasSidebar || state.isSidebarVisible || state.isSidebarPeeking || !state.titlebarRequests.isEmpty || state.isFullscreen
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1400, screen.width * 0.85), h = min(900, screen.height * 0.88)
        return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }

    func owns(_ window: NSWindow) -> Bool {
        window === self.window || window.parent === self.window
    }

    func focusContent() {
        state.viewport?.focusContent()
    }

    func persistFrame() {
        if let frame = window?.frame { state.frameDescriptor = NSStringFromRect(frame) }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { state.isKeyWindow = true }
    func windowDidResignKey(_ notification: Notification) {
        state.isKeyWindow = (window as? ShellWindow)?.childKeyWindowProvider?() ?? false
    }
    func windowDidResize(_ notification: Notification) { state.viewport?.layoutDidChange(); layoutOverlay(); persistFrame() }

    private func layoutOverlay() {
        guard let overlay, let window else { return }
        overlay.setFrame(window.convertToScreen(window.contentLayoutRect.union(window.contentView?.frame ?? .zero)), display: true)
    }
    func windowDidMove(_ notification: Notification) { state.viewport?.layoutDidChange(); persistFrame() }
    func windowDidEnterFullScreen(_ notification: Notification) { state.isFullscreen = true; state.viewport?.layoutDidChange(); layoutOverlay() }
    func windowDidExitFullScreen(_ notification: Notification) { state.isFullscreen = false; state.viewport?.layoutDidChange(); layoutOverlay() }
    func windowDidChangeScreen(_ notification: Notification) { state.viewport?.layoutDidChange() }

    func windowWillClose(_ notification: Notification) {
        persistFrame()
        if let overlay { window?.removeChildWindow(overlay); overlay.orderOut(nil) }
        state.viewport?.tearDown()
        shell?.windowDidClose(self)
    }
}
