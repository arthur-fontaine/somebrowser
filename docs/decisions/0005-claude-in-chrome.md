# 0005 — Claude in Chrome: what works today, and the patches for the rest

Date: 2026-10-16 · Status: patches 1 and 2 written (`chromium/0005`, `cef/0002`), not built yet; patch 3 proposed

## Context

Claude drives a browser through the Claude in Chrome extension (`fcoeoabgfenejglbffodgkkbkcdhcgfn`), from Claude Code
(`claude --chrome`) or the Claude apps. Read in the extension (1.0.100), Claude Code (2.1.301) and Claude Desktop
(2.37337.1) on 2026-10-16:

- **Connection.** The apps install a native messaging manifest (`com.anthropic.claude_code_browser_extension`,
  `com.anthropic.claude_browser_extension`) for a fixed list of browsers. The extension tries the Desktop host, then
  Claude Code's; both relay over a local socket (`/tmp/claude-mcp-browser-bridge-<user>/`), and Claude Code also
  reaches the extension through `wss://bridge.claudeusercontent.com` when both are signed in to the same account.
- **Tabs.** Each Claude session starts with `tabs_context_mcp {createIfEmpty: true}`:
  `windows.getLastFocused({windowTypes: ["normal"]})`, else `windows.create({type: "normal"})`, then
  `tabs.create({windowId})`, then at once `chrome.tabs.group` on the new tab and `tabGroups.update` (title "Claude" or
  the session's name). Each tab Claude uses gets `chrome.debugger.attach` and the extension's page marks (glow, Stop
  button, "Claude is active in this tab group").

Here (ADR-0002) each page is a CEF browser in a window of its own, and a tab Chrome makes by itself
(`chrome.tabs.create` from an extension) arrives in a stock Chrome window, which the browser closes and reopens as
its own tab. So:

1. the ids `tabs.create` / `windows.create` return are dead at once ("No tab with id");
2. no window is `normal` to `windows.getLastFocused` (CEF's views-hosted page windows are popups to extensions);
3. `tabs.group` can't gather tabs from several windows (Chromium's `TabsGroupFunction` moves them into one window,
   and won't into a popup).

## What works today (no patch)

- The CEF engine mirrors the user's Chrome native messaging manifests into its profile (`NativeMessagingHosts`), so
  Claude Code and the Claude apps (and 1Password…) reach the extension here.
- The Claude feature moves a tab the extension marks to the Claude space. Claude acting on a tab the user opened
  works (attach, read, click, type): it needs no new tab or group.

## The patches

Both written ones hang on one switch, `--views-hosted-new-tabs` (the CEF engine passes it; without our build it does
nothing).

1. **Chrome's new tabs keep their ids** (`chromium/0005`, `cef/0002`, written). CEF already hosts popups a page opens
   directly in a views browser of ours (`CanCreateWindow` → `OnBeforePopup`, `OnPopupWebContentsCreated` →
   `OnPopupBrowserViewCreated`, `AddWebContents` → a Browser for that view), keeping their WebContents and so their tab
   id. A new tab for one of our pages (`tabs.create` into its window, Chrome's new-tab commands) instead went through
   `chrome::Navigate` into a stock tabbed Browser, since a page's Browser holds one tab. `chrome::Navigate` now hands
   such a tab, before any stock Browser exists, to a new `cef::BrowserDelegate::OpenInNewBrowser`, which runs those
   same popup steps with the page's main frame as opener, then loads the URL. `windows.create({type: "normal"})` opens
   its URLs that way from the frontmost page and answers with the first new window. The app adopts the tab as it does
   a page's popups; from the page-less anchor (`CEFRuntime updateAnchor`), it adopts it as a tab of its own
   (`onEngineOpenedPage`). The new Browser is complete when `tabs.create` answers (CEF runs its window features'
   setup, the extension window controller included, while making it), and the anchor has a frame to stand as opener
   (CEF registers a page's main frame when it attaches, loaded or not). If the app declines the tab before anything
   is made of it (`OnBeforePopup` cancels, as when the opener is closing), it opens the old way: a stock window,
   adopted by URL.
2. **Pages are `normal` windows to extensions** (`chromium/0005`, written). CEF makes a views-hosted page's Browser
   `TYPE_POPUP` on purpose (`TYPE_NORMAL` would bring back Chrome's tab strip and toolbar features), so only the
   extension API's view changes: `GetTabsWindowType` reports such a Browser as `normal`. `windows.getLastFocused(
   {windowTypes: ["normal"]})` then finds the page in front, and `tabs.create({windowId})` lands in it (patch 1 makes
   it a tab of ours). A page's Browser has a tab group model already (only app windows don't), so
   `tabs.group({createProperties: {windowId}})` groups its one tab: a session's first tab works end to end.
3. **Groups across page windows (Chromium, proposed).** One window per tab means a group can't hold several tabs. Patch
   `TabsGroupFunction`/`TabGroupsUpdateFunction`/`tabs.query({groupId})` behind a switch (`--groups-across-windows`)
   so a group is a set of tab ids the browser keeps (not a tab strip span): grouping never moves tabs, `groupId` on
   each tab reports it, and `tabGroups.onCreated/onUpdated/onRemoved` fire as usual. The app reads the groups (CEF
   API `CefBrowserHost::GetTabGroupId`, new) and puts a Claude group's tabs in the Claude space directly, without
   waiting for the page marks.

Order: 1 and 2 make Claude Code work end to end with a single tab per session; 3 makes multi-tab sessions work (a
second tab Claude opens lands in a window of its own, and Claude groups a new tab only when it's in the group's
window). A smaller 3 to try first: the same `TabGroupId` in each page's own tab strip (`AddToGroupForRestore`) instead
of moving tabs, visuals copied to every window, and `tabGroups.onCreated`/`onRemoved` fired once per id.

Checks: the E2E test `extensionTabsKeepTheirIds` runs Claude's session steps through the probe extension
(`windows.getLastFocused`, `tabs.create`, `tabs.get` a second later, `tabs.group`, `tabGroups.update`, `tabs.query
({groupId})`, and the `windows.create` fallback) with `BROWSER_E2E_CEF_PATCHES` listing 0005. Chrome's new-tab page,
which Claude's tabs start on, would contact Google: the CEF page shows the browser's own new tab instead (E2E
`chromesNewTabPageIsTheBrowsers`, runs today).

## Consequences

- Until our build has patches 1 and 2, Claude can act on tabs the user opened, and they land in the Claude space; a
  session that opens its own tab fails at its first step ("No tab with id").
- Unverified until built: whether grouping the one tab of a `TYPE_POPUP` page's tab strip works (its group model
  exists; no tab strip view draws it).
- The patches change how every extension's `tabs.create` behaves here, for the better (ids that last, the TODO's
  open item): they're tested with the extension suite (ExtensionAPITests), not only Claude's.
