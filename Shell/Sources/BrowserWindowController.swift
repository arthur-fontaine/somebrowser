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

    static func isActive(_ window: NSWindow, keyWindow: NSWindow?) -> Bool {
        WindowFocus.isActive(window, keyWindow: keyWindow) { $0.parent }
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
        // An empty toolbar: the system's 52 pt titlebar, its traffic lights centered on the sidebar's top row.
        window.toolbar = NSToolbar(identifier: "browser")
        window.toolbarStyle = .unified
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
        window.childKeyWindowProvider = { [weak window] in
            guard let window, let key = NSApp.keyWindow, key !== window else { return false }
            return ShellWindow.isActive(window, keyWindow: key)
        }
        // Key moves between the window and its page or overlays without the window's own delegate calls telling.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshActiveState() }
            }
        }
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
            _ = state.isSidebarArriving
            _ = state.isSidebarPeeking
            _ = state.titlebarRequests
            _ = state.overlayFocusRequests
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateTrafficLights()
                self?.updateOverlayFocus()
                self?.observeChrome()
            }
        }
        updateTrafficLights()
    }

    /// Text input in overlays needs the overlay window to be key (pages are child windows under CEF).
    private func updateOverlayFocus() {
        guard let overlay else { return }
        if !state.overlayFocusRequests.isEmpty {
            if !overlay.isKeyWindow { overlay.makeKey() }
        } else if overlay.isKeyWindow {
            state.viewport?.focusContent()
        }
    }

    private func updateTrafficLights() {
        let hasSidebar = !runtime.ui.views(for: .sidebar).isEmpty
        let docked = state.isSidebarVisible && !state.isSidebarArriving  // they'd sit over the sidebar sliding under them
        // The floating sidebar draws its own in their place (it covers these).
        let visible = !hasSidebar || docked || (!state.isSidebarPeeking && (!state.titlebarRequests.isEmpty || state.isFullscreen))
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        let appearing = visible && buttons.contains(where: \.isHidden)
        for button in buttons {
            button.isHidden = !visible
            if appearing { button.alphaValue = 0 }
        }
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for button in buttons { button.animator().alphaValue = 1 }
            }
        }
        window?.toolbar?.isVisible = visible || (hasSidebar && state.isSidebarVisible)
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

    /// Active while key is anywhere in this window (see `ShellWindow.isActive`). Resigning key happens before the next
    /// window becomes key, so this also runs once the move is over.
    private func refreshActiveState() {
        guard let window else { return }
        let active = ShellWindow.isActive(window, keyWindow: NSApp.keyWindow)
        guard state.isKeyWindow != active else { return }
        state.isKeyWindow = active
        window.contentView?.superview?.needsDisplay = true  // the traffic lights follow `_hasActiveAppearance`
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshActiveState() }
    func windowDidResignKey(_ notification: Notification) { DispatchQueue.main.async { self.refreshActiveState() } }
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
