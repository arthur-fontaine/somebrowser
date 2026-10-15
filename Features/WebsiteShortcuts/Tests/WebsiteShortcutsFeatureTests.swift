import AppKit
import BrowserCore
import BrowserTesting
import Testing
@testable import FeatureWebsiteShortcuts

@MainActor
struct WebsiteShortcutsFeatureTests {
    func key(_ c: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    }

    @Test func pagesGetTheirShortcutsButNotNavigation() throws {
        let h = try TestHarness(features: [WebsiteShortcutsFeature.self], manifestDirectory: #filePath)
        h.runtime.commands.register([
            CommandDescriptor(id: "find.show", title: "Find", shortcut: "cmd+f"),
            CommandDescriptor(id: "tabs.close", title: "Close Tab", shortcut: "cmd+w"),
            CommandDescriptor(id: "tabs.select-1", title: "Tab 1", shortcut: "cmd+1"),
        ])
        let pageFirst = try #require(h.engine.hooks.pageFirstShortcut)
        #expect(!pageFirst(key("f")))  // off by default
        h.runtime.settings.set("website-shortcuts.prefer", true)
        #expect(pageFirst(key("f")))
        #expect(!pageFirst(key("w")))
        #expect(!pageFirst(key("1")))
        #expect(!pageFirst(key("k")))  // not the browser's: the page gets it anyway
    }
}
