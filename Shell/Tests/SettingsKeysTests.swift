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

    /// Through the real menu bar, as AppKit matches a key against it: ⌘← is Back from the browser window, and nothing
    /// while Settings has the keyboard.
    @Test func cmdLeftIsBackOnlyOutsideSettings() throws {
        _ = NSApplication.shared
        let h = try TestHarness(registrations: [])
        h.runtime.commands.register([CommandDescriptor(id: "test.back", title: "Back", shortcut: "cmd+[", alternateShortcuts: ["cmd+left"],
                                                       menu: "History")])
        var backs = 0
        h.runtime.commands.handle("test.back") { _ in backs += 1 }
        let shell = ShellController(runtime: h.runtime)
        let menus = MenuBuilder(runtime: h.runtime, shell: shell)
        menus.install()
        shell.showSettings(paneID: nil)
        let settings = try #require(shell.settingsWindow)
        let cmdLeft = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F702}",
                                                   charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        let browser = NSWindow()
        shell.keyWindow = { browser }
        #expect(NSApp.mainMenu?.performKeyEquivalent(with: cmdLeft) == true)
        #expect(backs == 1)
        shell.keyWindow = { settings }
        _ = NSApp.mainMenu?.performKeyEquivalent(with: cmdLeft)  // swallowed: AppKit's way with an item that's off
        #expect(backs == 1)
        settings.close()
    }

    /// A field in Settings gets the keys it edits with (⌘← to the line's start) before the menus, which would swallow
    /// them; other keys go on to the menus (⌘C, ⌘Q…).
    @Test func settingsFieldsGetTheirEditingKeys() throws {
        final class Field: NSTextView {
            var keys: [UInt16] = []
            override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
        }
        let (shell, _, _) = try shell()
        shell.showSettings(paneID: nil)
        let settings = try #require(shell.settingsWindow)
        let field = Field(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        settings.contentView?.addSubview(field)
        #expect(settings.makeFirstResponder(field))
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: settings.windowNumber,
                                          context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        #expect(settings.performKeyEquivalent(with: try key("\u{F702}", 123, [.command, .function, .numericPad])))
        #expect(!settings.performKeyEquivalent(with: try key("c", 8, .command)))
        #expect(field.keys == [123])
        settings.close()
    }

    /// The browser window's fields (the address, a rename) get ⌘ and ⇧⌘ with their editing keys before the menus, where
    /// ⌘← is Back; ⌥⌘→ (Next Space) and ⌘C still go on to the menus.
    @Test func browserFieldsGetTheirEditingKeys() throws {
        final class Field: NSTextView {
            var keys: [UInt16] = []
            override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
        }
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let field = Field(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(window.performKeyEquivalent(with: try key("\u{F702}", 123, arrow.union(.command))))
        #expect(window.performKeyEquivalent(with: try key("\u{F703}", 124, arrow.union([.command, .shift]))))
        #expect(!window.performKeyEquivalent(with: try key("\u{F703}", 124, arrow.union([.command, .option]))))
        #expect(!window.performKeyEquivalent(with: try key("c", 8, .command)))
        #expect(field.keys == [123, 124])
        window.makeFirstResponder(nil)
        #expect(!window.performKeyEquivalent(with: try key("\u{F702}", 123, arrow.union(.command))))
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
