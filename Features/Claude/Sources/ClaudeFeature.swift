import BrowserCore
import Foundation

/// Tabs Claude controls go to the Claude space. The Claude in Chrome extension marks the pages it acts on (its glow,
/// its Stop button, "Claude is active in this tab group"); a script sees the mark and the tab moves, with its
/// children. The user can move it back (Move to Your Tabs); private tabs stay private.
public final class ClaudeFeature: BrowserFeature {
    private let context: FeatureContext

    static let message = "claude.controlled"

    /// Watches for the extension's marks (elements with these ids, added to the page while Claude works on it).
    static let observerScript = """
    (() => {
      const ids = new Set(['claude-agent-glow-border', 'claude-agent-stop-container', 'claude-static-indicator-container']);
      let sent = false;
      const report = () => { if (!sent) { sent = true; window.__browser && window.__browser.post('\(message)', {}); } };
      const marked = node => node.nodeType === 1 && ids.has(node.id);
      new MutationObserver(records => {
        for (const r of records) for (const n of r.addedNodes) if (marked(n)) return report();
      }).observe(document, { childList: true, subtree: true });
      for (const id of ids) if (document.getElementById(id)) return report();
    })();
    """

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.hooks.addUserScript(UserScript(source: Self.observerScript, injectionTime: .documentEnd, mainFrameOnly: true, world: .isolated))
        context.hooks.handleFrameMessages(named: Self.message) { [weak self] page, message in
            guard message.isMainFrame else { return }
            self?.claudeControls(page)
        }
    }

    func claudeControls(_ page: EngineTab) {
        let runtime = context.runtime
        guard context.settings.bool("claude.space"),
              let tab = context.tabs.allTabs.first(where: { $0.engineTab === page }), !tab.isPrivate else { return }
        let claude = context.tabs.ensureSpace(.claude)
        guard context.tabs.spaceID(of: tab.id) != claude.id else { return }
        try? context.tabs.move(tab.id, to: .section(claude.id, .today), at: 0)
        // A window showing the tab follows it there.
        for w in runtime.windows where w.selectedTabID == tab.id { runtime.select(tab.id, in: w) }
    }
}
