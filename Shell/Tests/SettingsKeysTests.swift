import AppKit
import BrowserCore
import BrowserTesting
import Testing
@testable import BrowserShell

@MainActor
struct SettingsKeysTests {
    func shell() throws -> (ShellController, MenuBuilder, NSMenuItem) {
        let h = try TestHarness(registrations: [])
        h.runtime.commands.register([CommandDescriptor(id: "test.back", title: "Back", shortcut: "cmd+[", alternateShortcuts: ["cmd+left"])])
        h.runtime.commands.handle("test.back") { _ in }
        let shell = ShellController(runtime: h.runtime)
        let item = NSMenuItem()
        item.representedObject = "test.back"
        return (shell, MenuBuilder(runtime: h.runtime, shell: shell), item)
    }

    /// While Settings has the keyboard, the browser's commands are off, so their shortcuts (⌘← is Back) never reach
    /// the window behind it; the app's own items (Quit, Settings…, Edit) stay on.
    @Test func browserCommandsAreOffWhileSettingsHasTheKeyboard() throws {
        let (shell, menus, back) = try shell()
        shell.showSettings(paneID: nil)
        let settings = try #require(shell.settingsWindow)
        let browser = NSWindow()
        shell.keyWindow = { browser }
        #expect(menus.validateMenuItem(back))
        shell.keyWindow = { settings }
        #expect(!menus.validateMenuItem(back))
        #expect(menus.validateMenuItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")))
        settings.close()
    }

    /// ⌘W closes Settings ("Close Tab" is off there).
    @Test func commandWClosesSettings() throws {
        let (shell, _, _) = try shell()
        shell.showSettings(paneID: nil)
        let settings = try #require(shell.settingsWindow)
        #expect(settings.isVisible)
        let w = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                             windowNumber: settings.windowNumber, context: nil, characters: "w",
                                             charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(settings.performKeyEquivalent(with: w))
        #expect(!settings.isVisible)
    }
}
