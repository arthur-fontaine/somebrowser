import AppKit
import BrowserCore
import CEFBridge

/// Chrome's own dialogs (an extension asking for a permission, to be added, to remove itself…) in the browser's UI,
/// without rebuilding Chromium. Chrome's views dialogs are read through in-process accessibility, as the browser
/// presses Chrome's toolbar buttons (docs/decisions/0003): their heading, text and buttons go to `hooks.pageDialog`,
/// Chrome's window stays open but invisible, and the browser's answer presses Chrome's button. Dialogs holding more
/// than text and buttons (fields, check boxes, choosers, web pages such as extension popups) keep Chrome's UI.
@MainActor
final class ChromeDialogs {
    private let hooks: EngineHooks
    private var proxied: [ObjectIdentifier: DialogWithdrawal] = [:]
    /// Chrome ignores a dialog's buttons for a double-click interval after it shows (and again after it moves), against
    /// unintended clicks: presses wait that long, and are tried again while the dialog stays.
    private static var cooldown: TimeInterval { NSEvent.doubleClickInterval + 0.1 }
    private var observers: [NSObjectProtocol] = []

    struct Content: Equatable {
        var title: String
        var lines: [String]
        var buttons: [String]
    }

    enum Reading: Equatable {
        case dialog(Content)
        /// Not one we can show (or not a dialog).
        case unsupported
        /// Its accessibility tree isn't complete yet.
        case incomplete
    }

    init(hooks: EngineHooks) {
        self.hooks = hooks
        let center = NotificationCenter.default
        // The bridge announces Chrome's windows as they're shown (child windows too, for which AppKit posts nothing).
        for name in [NSNotification.Name.CEFChromeWindowShown, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.consider(window, attempts: 40) }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.closed(window) }
        })
    }

    private func consider(_ window: NSWindow, attempts: Int) {
        if proxied[ObjectIdentifier(window)] != nil {
            if !window.isVisible { return closed(window) }
            hide(window)  // in case Chrome showed it again
            return
        }
        // Chrome's views windows (bubbles fade in from transparent); the hidden toolbar's 1×1 window and pages' windows
        // aren't dialogs, nor Chrome's extensions menu (a child of that toolbar) while the browser runs an action through it.
        guard hooks.pageDialog != nil, window.isVisible, window.frame.width > 40,
              NSStringFromClass(type(of: window)) == "NativeWidgetMacNSWindow",
              !(CEFRuntime.shared().operatingChromeMenu && (window.parent?.frame.width ?? 2) <= 1) else { return }
        switch Self.read(window) {
        case .unsupported:
            return
        case .incomplete:
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard let window else { return }
                MainActor.assumeIsolated { self?.consider(window, attempts: attempts - 1) }
            }
        case .dialog(let content):
            show(content, for: window)
        }
    }

    private func show(_ content: Content, for window: NSWindow) {
        let withdrawal = DialogWithdrawal()
        proxied[ObjectIdentifier(window)] = withdrawal
        hide(window)
        let shown = Date()
        let dialog = PageDialog(kind: .engine(title: content.title, buttons: content.buttons),
                                message: content.lines.joined(separator: "\n"), origin: nil, tab: nil, withdrawal: withdrawal)
        hooks.pageDialog?(dialog) { [weak self, weak window] answer in
            guard let window else { return }
            let index = answer.button ?? (answer.accepted ? content.buttons.count - 1 : 0)
            let wait = max(0, shown.addingTimeInterval(Self.cooldown).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak window] in
                guard let window else { return }
                MainActor.assumeIsolated { self?.press(index, in: window, attempts: 3) }
            }
        }
    }

    /// Invisible, and clicks go through to the browser's own dialog. Focus stays: Chrome's bubbles close (cancelled)
    /// when they lose it, and Return or Escape there does what the browser's dialog would (its default button, or
    /// cancel), the browser's dialog following.
    private func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    private func closed(_ window: NSWindow) {
        proxied.removeValue(forKey: ObjectIdentifier(window))?.withdraw()
    }

    private func press(_ index: Int, in window: NSWindow, attempts: Int) {
        guard window.isVisible else { return }  // answered: Chrome closed it
        var buttons: [NSObject] = []
        Self.walk(window) { element, role, _ in
            if role == "AXButton", !Self.text(of: element).isEmpty { buttons.append(element) }
        }
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard buttons.indices.contains(index), buttons[index].responds(to: press) else { return window.performClose(nil) }
        buttons[index].perform(press)
        guard attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cooldown) { [weak self, weak window] in
            guard let window else { return }
            MainActor.assumeIsolated { self?.press(index, in: window, attempts: attempts - 1) }
        }
    }

    // MARK: Reading

    static func read(_ window: NSWindow) -> Reading {
        var title: String?
        var texts: [(text: String, depth: Int)] = []
        var buttons: [String] = []
        var isDialog = false
        var unsupported = false
        let controls: Set<String> = ["AXWebArea", "AXTextField", "AXTextArea", "AXSecureTextField", "AXCheckBox", "AXRadioButton",
                                     "AXPopUpButton", "AXComboBox", "AXTable", "AXOutline", "AXList", "AXSlider", "AXMenuButton"]
        walk(window) { element, role, depth in
            let subrole = value(element, "accessibilitySubrole").map { "\($0)" } ?? ""
            if role == "AXSheet" || subrole.hasSuffix("Dialog") { isDialog = true }
            if controls.contains(role) { unsupported = true }
            switch role {
            case "AXHeading":
                if title == nil, !text(of: element).isEmpty { title = text(of: element) }
            case "AXStaticText":
                let t = text(of: element)
                if !t.isEmpty, t != title { texts.append((t, depth)) }
            case "AXButton":
                let t = text(of: element)
                if !t.isEmpty { buttons.append(t) }
            default:
                break
            }
        }
        if unsupported { return .unsupported }
        guard isDialog, !buttons.isEmpty else { return .incomplete }
        // Lines nested deeper than the first ones are a list ("It could:", then each permission).
        let top = texts.map(\.depth).min() ?? 0
        let lines = texts.map { $0.depth > top ? "• " + $0.text : $0.text }
        return .dialog(Content(title: title ?? window.title, lines: lines, buttons: buttons))
    }

    /// Depth-first over the window's accessibility tree (Chromium's views nodes are plain objects: read by selector).
    static func walk(_ window: NSWindow, _ visit: (NSObject, String, Int) -> Void) {
        func go(_ element: NSObject, _ depth: Int) {
            guard depth < 40 else { return }
            visit(element, value(element, "accessibilityRole").map { "\($0)" } ?? "", depth)
            for child in (value(element, "accessibilityChildren") as? [NSObject]) ?? [] { go(child, depth + 1) }
        }
        go(window, 0)
    }

    static func value(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }

    /// What an element shows: its value (static text), else its title, else its label.
    static func text(of element: NSObject) -> String {
        for key in ["accessibilityValue", "accessibilityTitle", "accessibilityLabel"] {
            if let s = value(element, key) as? String, !s.isEmpty { return s }
        }
        return ""
    }
}
