import AppKit
import BrowserCore
import SwiftUI

/// App delegate + window management. Generic: it knows windows and slots, never features.
final class ShellController: NSObject, NSApplicationDelegate, ShellServices {
    let runtime: BrowserRuntime
    private(set) var controllers: [UUID: BrowserWindowController] = [:]
    private var launched = false
    private var engineReady = false
    private var pendingURLs: [URL] = []
    private var savedWindows: [SessionSnapshot.WindowRecord] = []
    private var menuBuilder: MenuBuilder?
    private(set) var settingsWindow: SettingsWindow?
    /// The app's key window. Tests set it: no window becomes key in a process that isn't the frontmost app.
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    private var automation: AutomationServer?

    init(runtime: BrowserRuntime) {
        self.runtime = runtime
        super.init()
        runtime.commands.currentWindow = { [weak self] in self?.keyWindowState }
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        savedWindows = runtime.loadSession()
        runtime.activateFeatures()
        menuBuilder = MenuBuilder(runtime: runtime, shell: self)
        menuBuilder?.install()
        if let socket = ProcessInfo.processInfo.environment["BROWSER_AUTOMATION_SOCKET"] {
            automation = AutomationServer(path: socket, runtime: runtime, shell: self)
            automation?.start()
        }
        launched = true
        openInitialWindowsIfPossible()
    }

    func engineDidBecomeReady() {
        engineReady = true
        runtime.events.publish(EngineReady())
        openInitialWindowsIfPossible()
    }

    private func openInitialWindowsIfPossible() {
        guard launched, engineReady, controllers.isEmpty else { return }
        if savedWindows.isEmpty || ProcessInfo.processInfo.environment["BROWSER_FRESH_WINDOW"] != nil {
            openWindow(spaceID: nil, isPrivate: false, initialURL: nil)
        } else {
            for record in savedWindows { restore(record) }
        }
        savedWindows = []
        let urls = pendingURLs
        pendingURLs = []
        open(urls)
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard engineReady, launched else { pendingURLs += urls; return }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        let remaining = urls.filter { url in !runtime.externalURLHandlers.contains { $0(url) } }
        guard !remaining.isEmpty else { return }
        let window = keyWindowState ?? openWindow(spaceID: nil, isPrivate: false, initialURL: nil)
        for url in remaining {
            // Links from other apps reuse an existing tab for the same URL (Horse).
            if let existing = runtime.tabs.tabs(matching: url, in: window.spaceID).first {
                runtime.select(existing.id, in: window)
            } else {
                runtime.openTab(url, in: window)
            }
        }
        controllers[window.id]?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { openWindow(spaceID: nil, isPrivate: false, initialURL: nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers.values { c.persistFrame() }
        runtime.deactivateFeatures()
        // Gone at once: the engine's shutdown blocks the main thread (Chromium's took 0.4–6.5 s, measured
        // 2026-10-15), and windows left on screen would sit there frozen until the process exits.
        NSApp.windows.forEach { $0.orderOut(nil) }
        runtime.engine.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: ShellServices

    var keyWindowState: BrowserWindowState? {
        if let key = NSApp.keyWindow, let c = controllers.values.first(where: { $0.owns(key) }) { return c.state }
        if let main = NSApp.mainWindow, let c = controllers.values.first(where: { $0.owns(main) }) { return c.state }
        return controllers.values.first?.state
    }

    @discardableResult
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?, placement: BrowserWindowPlacement?) -> BrowserWindowState {
        let state = runtime.makeWindowState(spaceID: spaceID ?? keyWindowState?.spaceID, isPrivate: isPrivate)
        let controller = BrowserWindowController(state: state, runtime: runtime, shell: self, placement: placement)
        controllers[state.id] = controller
        controller.showWindow(nil)
        if let initialURL {
            runtime.openTab(initialURL, in: state)
        } else if let first = runtime.tabs.orderedTabs(in: state.spaceID).first, !isPrivate,
                  !controllers.values.contains(where: { $0.state !== state && $0.state.selectedTabID == first.id }) {
            runtime.select(first.id, in: state)
        }
        return state
    }

    private func restore(_ record: SessionSnapshot.WindowRecord) {
        let state = runtime.makeWindowState(spaceID: record.spaceID, id: record.id)
        state.isSidebarVisible = record.isSidebarVisible
        state.sidebarWidth = CGFloat(record.sidebarWidth)
        state.frameDescriptor = record.frame
        let controller = BrowserWindowController(state: state, runtime: runtime, shell: self)
        controllers[state.id] = controller
        controller.showWindow(nil)
        runtime.select(record.selectedTabID, in: state)
    }

    func closeWindow(_ window: BrowserWindowState) { controllers[window.id]?.close() }

    func windowDidClose(_ controller: BrowserWindowController) {
        controllers[controller.state.id] = nil
        runtime.removeWindow(controller.state)
    }

    func nsWindow(for window: BrowserWindowState) -> NSWindow? { controllers[window.id]?.window }

    func focusContent(in window: BrowserWindowState) { controllers[window.id]?.focusContent() }

    func contentLayoutDidChange(in window: BrowserWindowState) { window.viewport?.layoutDidChange() }

    func showSettings(paneID: String?) {
        // A page asked for opens on it even when the window is already open.
        if settingsWindow == nil || paneID != nil {
            let w = settingsWindow ?? SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                                     backing: .buffered, defer: false)
            if settingsWindow == nil {
                w.title = "\(Brand.name) Settings"
                w.isReleasedWhenClosed = false
                w.contentMinSize = NSSize(width: 700, height: 460)
                w.titlebarAppearsTransparent = true
                w.toolbarStyle = .unified
                w.center()
                settingsWindow = w
            }
            w.contentView = NSHostingView(rootView: SettingsRootView(initialPane: paneID).environment(BrowserEnvironment(runtime: runtime)))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Settings has the keyboard: the browser's shortcuts don't reach the browser behind it.
    var settingsHasKeyboard: Bool { settingsWindow.map { keyWindow() === $0 } ?? false }
}

/// The Settings window. The browser's commands are off while it has the keyboard (`MenuBuilder`), so ⌘W, which is
/// "Close Tab", closes it as in any other app.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        // Whatever the modifiers: the browser's items are all off here.
        return FieldEditingKeys.send(event, toFieldIn: self, anyModifiers: true)
    }
}
