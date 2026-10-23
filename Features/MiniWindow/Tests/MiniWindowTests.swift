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
    var placements: [BrowserWindowPlacement?] = []
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?, placement: BrowserWindowPlacement?) -> BrowserWindowState {
        placements.append(placement)
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
        let placement = try #require(shell.placements.last ?? nil)
        #expect(placement.level == .floating && placement.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary] && placement.isPanel)
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

    @Test func closingThePageClosesTheMiniWindow() throws {
        let h = try TestHarness(features: [MiniWindowFeature.self], manifestDirectory: #filePath)
        let shell = StubShell(runtime: h.runtime)
        h.runtime.shell = shell
        let feature = try #require(h.runtime.feature(MiniWindowFeature.self))
        let mini = try #require(feature.open(URL(string: "https://x.example")))
        h.runtime.close(try #require(mini.selectedTabID), includingDescendants: true)
        #expect(shell.closed == [mini.id])
    }

    @Test func opensOnThePointerAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let centered = MiniWindowFeature.frame(around: CGPoint(x: 1000, y: 600), in: screen)
        #expect(centered.midX == 1000 && centered.midY == 600 && centered.size == CGSize(width: 960, height: 720))
        let corner = MiniWindowFeature.frame(around: CGPoint(x: 1990, y: 5), in: screen)
        #expect(corner.maxX == 2000 && corner.minY == 0)
        let second = CGRect(x: -1440, y: 0, width: 1440, height: 900)  // a screen left of the main one
        #expect(second.contains(MiniWindowFeature.frame(around: CGPoint(x: -700, y: 450), in: second)))
    }

    @Test func settingOffLetsTheShellHandleLinks() throws {
        let h = try TestHarness(features: [MiniWindowFeature.self], manifestDirectory: #filePath)
        h.runtime.shell = StubShell(runtime: h.runtime)
        h.runtime.settings.set("mini-window.forExternalLinks", false)
        #expect(!h.runtime.externalURLHandlers.contains { $0(URL(string: "https://link.example")!) })
    }
}
