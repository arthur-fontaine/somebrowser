import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureMiniWindow

/// Minimal window layer for features that open/close windows.
final class StubShell: ShellServices {
    let runtime: BrowserRuntime
    var closed: [UUID] = []
    init(runtime: BrowserRuntime) { self.runtime = runtime }
    var keyWindowState: BrowserWindowState? { runtime.windows.last }
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?, prepare: ((NSWindow) -> Void)?) -> BrowserWindowState {
        let w = runtime.makeWindowState(spaceID: spaceID, isPrivate: isPrivate)
        w.viewport = runtime.engine.makeViewport(in: NSView())
        return w
    }
    func closeWindow(_ window: BrowserWindowState) {
        closed.append(window.id)
        runtime.removeWindow(window)
    }
    func nsWindow(for window: BrowserWindowState) -> NSWindow? { nil }
    func showSettings(paneID: String?) {}
    func focusContent(in window: BrowserWindowState) {}
    func contentLayoutDidChange(in window: BrowserWindowState) {}
}

@MainActor
struct MiniWindowTests {
    @Test func externalLinksOpenInAMiniWindowAndMoveToMain() throws {
        let h = try TestHarness(features: [MiniWindowFeature.self], manifestDirectory: #filePath)
        let shell = StubShell(runtime: h.runtime)
        h.runtime.shell = shell
        let handled = h.runtime.externalURLHandlers.contains { $0(URL(string: "https://link.example")!) }
        #expect(handled)
        let mini = try #require(h.runtime.windows.first { $0.flags.contains(MiniWindowFeature.flag) })
        #expect(!mini.isSidebarVisible)
        let tabID = try #require(mini.selectedTabID)
        #expect(throws: CommandError.self) { try h.run("mini-window.move-to-main") }  // disabled outside mini windows
        h.runtime.commands.currentWindow = { mini }
        try h.runtime.commands.run("mini-window.move-to-main")
        #expect(h.window.selectedTabID == tabID)
        #expect(shell.closed == [mini.id])
        #expect(h.runtime.tabs.tab(tabID) != nil)
    }

    @Test func closingTheMiniWindowClosesItsPage() throws {
        let h = try TestHarness(features: [MiniWindowFeature.self], manifestDirectory: #filePath)
        let shell = StubShell(runtime: h.runtime)
        h.runtime.shell = shell
        let feature = try #require(h.runtime.feature(MiniWindowFeature.self))
        let mini = try #require(feature.open(URL(string: "https://x.example")))
        #expect(h.runtime.tabs.tabCount == 1)
        shell.closeWindow(mini)
        #expect(h.runtime.tabs.tabCount == 0)
    }

    @Test func settingOffLetsTheShellHandleLinks() throws {
        let h = try TestHarness(features: [MiniWindowFeature.self], manifestDirectory: #filePath)
        h.runtime.shell = StubShell(runtime: h.runtime)
        h.runtime.settings.set("mini-window.forExternalLinks", false)
        #expect(!h.runtime.externalURLHandlers.contains { $0(URL(string: "https://link.example")!) })
    }
}
