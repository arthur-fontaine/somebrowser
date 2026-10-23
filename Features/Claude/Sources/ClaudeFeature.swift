import BrowserCore
import Foundation

/// Tabs Claude controls go to the Claude space. The Claude in Chrome extension opens a session's tabs in the background
/// on Chrome's new-tab page, which only an extension can open: those go there as they open. On the user's tabs, it
/// marks the pages it acts on (its glow, its Stop button, "Claude is active in this tab group"); a script sees the mark
/// and the tab moves, with its children. The user can move it back (Move to Your Tabs); private tabs stay private.
/// While Claude works on a tab of its space (it navigates, clicks, types, scrolls), the tab and the space say so
/// (`agentActedAt`): the extension's own working marks are out of the page's reach.
public final class ClaudeFeature: BrowserFeature {
    private let context: FeatureContext

    static let message = "claude.controlled"
    static let actedMessage = "claude.acted"

    /// Watches for the extension's marks, added to the page while Claude works on it. Before 1.0.102 they were elements
    /// with these ids; since, they sit in a closed shadow root whose host is all that shows: a bare, empty `div` at the
    /// end of `<body>`, `display: contents` from the shadow's `:host` rule. On a marked page, Claude's input (trusted
    /// events: it drives the page through the debugger) is reported, twice a second at most.
    static let observerScript = """
    (() => {
      const ids = new Set(['claude-agent-glow-border', 'claude-agent-stop-container', 'claude-static-indicator-container']);
      let sent = false, actedAt = -Infinity;
      const acted = e => {
        if (!e.isTrusted || e.timeStamp - actedAt < 500) return;
        actedAt = e.timeStamp;
        window.__browser && window.__browser.post('\(actedMessage)', {});
      };
      const report = () => {
        if (sent) return;
        sent = true;
        window.__browser && window.__browser.post('\(message)', {});
        for (const type of ['pointerdown', 'keydown', 'wheel']) addEventListener(type, acted, { capture: true, passive: true });
      };
      const host = node => node.tagName === 'DIV' && node.attributes.length === 0 && !node.firstChild
        && (node.parentNode === document.body || node.parentNode === document.documentElement)
        && getComputedStyle(node).display === 'contents';
      const marked = node => node.nodeType === 1 && (ids.has(node.id) || host(node));
      new MutationObserver(records => {
        for (const r of records) for (const n of r.addedNodes) if (marked(n)) return report();
      }).observe(document, { childList: true, subtree: true });
      for (const id of ids) if (document.getElementById(id)) return report();
      for (const n of [...(document.body?.children ?? []), ...document.documentElement.children]) if (host(n)) return report();
    })();
    """

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.hooks.addUserScript(UserScript(source: Self.observerScript, injectionTime: .documentEnd, mainFrameOnly: true, world: .isolated))
        context.hooks.handleFrameMessages(named: Self.message) { [weak self] page, message in
            guard message.isMainFrame, let tab = self?.context.tabs.allTabs.first(where: { $0.engineTab === page }) else { return }
            self?.claudeControls(tab)
        }
        context.hooks.handleFrameMessages(named: Self.actedMessage) { [weak self] page, message in
            guard message.isMainFrame, let tab = self?.context.tabs.allTabs.first(where: { $0.engineTab === page }) else { return }
            self?.claudeActed(on: tab)
        }
        context.events.subscribe(TabNavigated.self) { [weak self] navigated in
            guard let tab = self?.context.tabs.tab(navigated.tabID) else { return }
            self?.claudeActed(on: tab)
        }
        // `tabs.create({url: "chrome://newtab/", active: false})`: the engine reports Chrome's new-tab page as no URL
        // when no page of ours stands as its opener.
        context.events.subscribe(TabOpened.self) { [weak self] opened in
            guard opened.disposition == .backgroundTab, let tab = self?.context.tabs.tab(opened.tabID),
                  tab.url.map(Self.isChromeNewTabPage) ?? true else { return }
            self?.claudeControls(tab)
        }
    }

    static func isChromeNewTabPage(_ url: URL) -> Bool { url.scheme == "chrome" && url.host == "newtab" }

    func claudeControls(_ tab: BrowserTab) {
        let runtime = context.runtime
        guard context.settings.bool("claude.space"), !tab.isPrivate else { return }
        let claude = context.tabs.ensureSpace(.claude)
        defer { claudeActed(on: tab) }
        guard context.tabs.spaceID(of: tab.id) != claude.id else { return }
        try? context.tabs.move(tab.id, to: .section(claude.id, .today), at: 0)
        // A window showing the tab follows it there.
        for w in runtime.windows where w.selectedTabID == tab.id { runtime.select(tab.id, in: w) }
    }

    /// Only in Claude's space: elsewhere a page's navigations and input are the user's.
    func claudeActed(on tab: BrowserTab) {
        guard let space = context.tabs.spaceID(of: tab.id).flatMap(context.tabs.space), space.kind == .claude else { return }
        let now = Date()
        tab.agentActedAt = now
        space.agentActedAt = now
    }
}
