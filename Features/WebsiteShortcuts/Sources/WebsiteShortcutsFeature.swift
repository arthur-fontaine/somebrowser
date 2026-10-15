import AppKit
import BrowserCore

/// "Prefer website shortcuts" (Arc): with it on, the engine gives a focused page the browser shortcuts it uses (⌘F in
/// Docs, ⌘D in Figma…) and runs the browser's command when the page doesn't, or when the shortcut is pressed twice.
public final class WebsiteShortcutsFeature: BrowserFeature {
    private let context: FeatureContext
    /// What you rely on to get around always stays the browser's.
    static let browserOnly: Set<String> = [
        "command-bar.open", "command-bar.edit-url", "tabs.new-window", "tabs.new-private-window", "tabs.close",
        "tabs.close-window", "tabs.reopen", "tab-switcher.next", "tab-switcher.previous",
    ]
    static let browserOnlyPrefixes = ["tabs.select-", "spaces.select-"]

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.hooks.pageFirstShortcut = { [weak self] event in self?.isPageFirst(event) ?? false }
    }

    func isPageFirst(_ event: NSEvent) -> Bool {
        guard context.settings.bool("website-shortcuts.prefer"), let id = command(for: event) else { return false }
        return !Self.browserOnly.contains(id) && !Self.browserOnlyPrefixes.contains { id.hasPrefix($0) }
    }

    /// The command bound to this key (user remaps included).
    func command(for event: NSEvent) -> String? {
        let commands = context.runtime.commands
        return commands.descriptors.first { d in
            commands.shortcut(for: d.id)?.matches(event) == true || commands.alternateShortcuts(for: d.id).contains { $0.matches(event) }
        }?.id
    }
}
