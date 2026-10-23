import AppKit

/// A keyboard shortcut parsed from manifest strings like `cmd+shift+t`, `cmd+[`, `ctrl+tab`, `cmd+opt+left`.
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    /// Lowercased key name: a character (`t`, `[`, `1`) or a named key (`left`, `tab`, `return`, `f12`…).
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public init?(_ string: String) {
        var parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if string.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "alt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "fn": mods.insert(.function)
            default: return nil
            }
        }
        self.init(key: key, modifiers: mods)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.function) { parts.append("fn") }
        return (parts + [key]).joined(separator: "+")
    }

    static let named: [String: (equivalent: Int, symbol: String)] = [
        "left": (NSLeftArrowFunctionKey, "←"), "right": (NSRightArrowFunctionKey, "→"),
        "up": (NSUpArrowFunctionKey, "↑"), "down": (NSDownArrowFunctionKey, "↓"),
        "tab": (0x09, "⇥"), "return": (0x0D, "↩"), "enter": (0x0D, "↩"), "escape": (0x1B, "⎋"), "esc": (0x1B, "⎋"),
        "space": (0x20, "Space"), "delete": (0x08, "⌫"), "backspace": (0x08, "⌫"), "forwarddelete": (NSDeleteFunctionKey, "⌦"),
        "home": (NSHomeFunctionKey, "↖"), "end": (NSEndFunctionKey, "↘"),
        "pageup": (NSPageUpFunctionKey, "⇞"), "pagedown": (NSPageDownFunctionKey, "⇟"),
        "f1": (NSF1FunctionKey, "F1"), "f2": (NSF2FunctionKey, "F2"), "f3": (NSF3FunctionKey, "F3"), "f4": (NSF4FunctionKey, "F4"),
        "f5": (NSF5FunctionKey, "F5"), "f6": (NSF6FunctionKey, "F6"), "f7": (NSF7FunctionKey, "F7"), "f8": (NSF8FunctionKey, "F8"),
        "f9": (NSF9FunctionKey, "F9"), "f10": (NSF10FunctionKey, "F10"), "f11": (NSF11FunctionKey, "F11"), "f12": (NSF12FunctionKey, "F12"),
        "backtick": (0x60, "`"),
    ]

    /// `NSMenuItem.keyEquivalent`.
    public var keyEquivalent: String {
        if let n = Self.named[key], let scalar = UnicodeScalar(n.equivalent) { return String(Character(scalar)) }
        return key
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.function) { f.insert(.function) }
        return f
    }

    /// Human form, e.g. `⌃⌥⇧⌘T`.
    /// One string per key, as keycaps show them (⌥, ⌘, N).
    public var keycaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        if modifiers.contains(.function) { caps.append("fn") }
        return caps + [Self.named[key]?.symbol ?? key.uppercased()]
    }

    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        if modifiers.contains(.function) { s += "fn " }
        return s + (Self.named[key]?.symbol ?? key.uppercased())
    }

    /// Matches a key-down event (layout-aware through `charactersIgnoringModifiers`).
    public func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.intersection(relevant) == modifierFlags.intersection(relevant) else { return false }
        if let n = Self.named[key] {
            if n.equivalent == 0x09 { return event.keyCode == 48 }
            if n.equivalent == 0x1B { return event.keyCode == 53 }
            if n.equivalent == 0x0D { return event.keyCode == 36 || event.keyCode == 76 }
            if n.equivalent == 0x08 { return event.keyCode == 51 }
            guard let chars = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
            return Int(chars.value) == n.equivalent
        }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if chars == key { return true }
        // ⇧ changes the produced character on most layouts (⌘⇧[ yields "{"): compare the unshifted key too.
        if modifiers.contains(.shift), let unshifted = event.characters(byApplyingModifiers: [])?.lowercased() {
            return unshifted == key
        }
        return false
    }
}
