import AppKit
import BrowserCore

/// Builds the native menu bar from command descriptors (title, menu, group, order, shortcut).
/// Every shortcut therefore works through AppKit's standard key-equivalent path, shows in menus, and is
/// discoverable — features never touch NSMenu.
final class MenuBuilder: NSObject, NSMenuItemValidation {
    private let runtime: BrowserRuntime
    private weak var shell: ShellController?
    static let menuOrder = ["File", "Edit", "View", "History", "Bookmarks", "Spaces", "Tabs", "Tools", "Window", "Help"]

    init(runtime: BrowserRuntime, shell: ShellController) {
        self.runtime = runtime
        self.shell = shell
        super.init()
    }

    func install() {
        NSApp.mainMenu = build()
        observeShortcutChanges()
    }

    private func observeShortcutChanges() {
        withObservationTracking { _ = runtime.commands.userShortcuts } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                NSApp.mainMenu = self.build()
                self.observeShortcutChanges()
            }
        }
    }

    func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))

        var byMenu: [String: [CommandDescriptor]] = [:]
        for d in runtime.commands.descriptors { if let m = d.menu { byMenu[m, default: []].append(d) } }
        let names = Self.menuOrder + byMenu.keys.filter { !Self.menuOrder.contains($0) }.sorted()
        for name in names {
            let menu = NSMenu(title: name)
            switch name {
            case "Edit": addStandardEdit(to: menu)
            case "View": break
            case "Window": addStandardWindow(to: menu)
            default: break
            }
            add(byMenu[name] ?? [], to: menu)
            if name == "View" {
                if menu.items.count > 0 { menu.addItem(.separator()) }
                menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.control, .command]
            }
            if name == "Window" { NSApp.windowsMenu = menu }
            if name == "Help" { NSApp.helpMenu = menu }
            guard menu.items.count > 0 || name == "Window" else { continue }
            main.addItem(submenu(menu))
        }
        return main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func add(_ commands: [CommandDescriptor], to menu: NSMenu) {
        let groups = Dictionary(grouping: commands, by: { $0.group ?? "" })
        let ordered = groups.sorted { a, b in
            (a.value.map(\.order).min() ?? 0, a.key) < (b.value.map(\.order).min() ?? 0, b.key)
        }
        for (_, items) in ordered {
            if menu.items.count > 0, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            for d in items.sorted(by: { ($0.order, $0.title) < ($1.order, $1.title) }) {
                menu.addItem(item(for: d))
                for alt in runtime.commands.alternateShortcuts(for: d.id) {
                    let hidden = item(for: d, shortcut: alt)
                    hidden.isHidden = true
                    hidden.allowsKeyEquivalentWhenHidden = true
                    menu.addItem(hidden)
                }
            }
        }
    }

    private func item(for d: CommandDescriptor, shortcut: KeyShortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: d.title, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = d.id
        if let s = shortcut ?? runtime.commands.shortcut(for: d.id) {
            item.keyEquivalent = s.keyEquivalent
            item.keyEquivalentModifierMask = s.modifierFlags
        }
        item.identifier = NSUserInterfaceItemIdentifier(d.id)
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do { try runtime.commands.run(id) } catch { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String else { return true }
        return runtime.commands.canRun(id)
    }

    // MARK: Undo: typing first, then the sidebar (Arc)

    @objc func undo(_ sender: Any?) { route(undo: true, sender) }
    @objc func redo(_ sender: Any?) { route(undo: false, sender) }

    /// A text field with the keyboard (ours, or a page's) undoes its typing; otherwise ⌘Z undoes the last sidebar change.
    private func route(undo: Bool, _ sender: Any?) {
        let action = Selector(undo ? "undo:" : "redo:")
        let state = shell?.keyWindowState
        let sidebar = { [runtime] in if undo { runtime.sidebarHistory.undo(in: state) } else { runtime.sidebarHistory.redo(in: state) } }
        guard let key = NSApp.keyWindow else { return sidebar() }
        if key.firstResponder is NSText { NSApp.sendAction(action, to: nil, from: sender); return }
        let pageHasKeyboard = key.parent != nil && key.identifier != ShellOverlay.windowIdentifier
        guard pageHasKeyboard, let state, let page = runtime.selectedTab(in: state)?.engineTab else { return sidebar() }
        page.evaluateJavaScript(Self.pageIsEditing) { result in
            if case .success(let value) = result, value.map({ "\($0)" }) == "false" { sidebar() }
            else { NSApp.sendAction(action, to: nil, from: sender) }  // editing (or unsure): the page's own undo
        }
    }

    /// Whether the page's focus is somewhere it types (frames count: they may be editors).
    static let pageIsEditing = """
    String((() => { const e = document.activeElement; return !!e && (e.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT', 'IFRAME'].includes(e.tagName)); })())
    """

    // MARK: Standard menus

    private func appMenu() -> NSMenu {
        let m = NSMenu(title: Brand.name)
        m.addItem(withTitle: "About \(Brand.name)", action: #selector(showAbout), keyEquivalent: "").target = self
        m.addItem(.separator())
        let settings = m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(withTitle: "Hide \(Brand.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }

    private func addStandardEdit(to m: NSMenu) {
        m.addItem(withTitle: "Undo", action: #selector(undo(_:)), keyEquivalent: "z").target = self
        // "Z": AppKit's ⇧⌘Z (the shift is in the capital); "z" with a shift mask can lose ⇧⌘Z to Undo's ⌘Z.
        m.addItem(withTitle: "Redo", action: #selector(redo(_:)), keyEquivalent: "Z").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v").keyEquivalentModifierMask = [.command, .option, .shift]
        m.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        m.addItem(.separator())
        m.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ").keyEquivalentModifierMask = [.command, .control]
    }

    private func addStandardWindow(to m: NSMenu) {
        m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        m.addItem(.separator())
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.name,
            .credits: NSAttributedString(string: "\(Brand.copyright)\nEngine: \(Brand.engineName)\n\(Brand.homepage)"),
        ])
    }

    @objc private func showSettings() { shell?.showSettings(paneID: nil) }
}
