import AppKit
import Carbon.HIToolbox

/// A text field's editing keys, which reach it only after the menus have had them as key equivalents: there an item
/// (⌘← is Back, ⇧⌘← Select Parent Tab) would swallow them, enabled or not. Windows hand them to the field first.
enum FieldEditingKeys {
    /// Arrows, delete, forward delete, home and end.
    static let keys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Delete, kVK_ForwardDelete, kVK_Home, kVK_End]

    /// Sends `event` to the text view with `window`'s keyboard if it edits with it. `anyModifiers` false: only with ⌘ or
    /// ⇧⌘ (⌘← to the line's start, ⇧⌘→ selects to its end); ⌥⌘→ (Next Space) and the like stay the menus'.
    static func send(_ event: NSEvent, toFieldIn window: NSWindow, anyModifiers: Bool = false) -> Bool {
        guard let field = window.firstResponder as? NSTextView, keys.contains(Int(event.keyCode)) else { return false }
        if !anyModifiers {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        }
        field.keyDown(with: event)
        return true
    }
}
