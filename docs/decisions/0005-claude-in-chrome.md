# 0005 — Claude in Chrome: what works today, and the patches for the rest

Date: 2026-10-16 · Status: patches 1 to 3 built and checked (`chromium/0005`, `chromium/0006`, `cef/0002`, 2026-10-16:
E2E `extensionTabsKeepTheirIds` runs a two-tab session)

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

All three hang on one switch, `--views-hosted-new-tabs` (the CEF engine passes it; without our build it does
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
3. **Groups span pages** (`chromium/0006`, written). One window per tab means a group can't hold several tabs, and
   Chromium's `TabsGroupFunction` moves tabs into the group's window. Each later tab of a session opens in the
   group's window (`tabGroups.get(groupId).windowId`), so in a page of its own (patch 1), then joins with
   `tabs.group({tabIds, groupId})`. Between pages, that now joins each tab to the group in its own page's tab strip,
   under the same `TabGroupId` (`AddToGroupForRestore`), instead of moving it: `tabs.query({groupId})` finds every
   member, `tabGroups.query` lists the group once, and `tabGroups.update` gives every page holding it the same look.
   Chrome's saved tab groups are off with the switch (`IsTabGroupSyncEnabled`): they follow a group in one tab strip
   (a second strip making the same group fails a `CHECK`), and the browser shows none of them. Not done:
   `tabGroups.onCreated`/`onRemoved` fire once per page holding the group (Claude listens to neither), and the app
   doesn't read groups (the page marks bring a session's tabs to the Claude space).

Order: 1 and 2 make Claude Code work end to end with a single tab per session; 3 makes multi-tab sessions work.

Correction (2026-10-16, extension 1.0.100): an earlier note here said multi-tab sessions need every page of a browser
window to report one window id. The comparison it quoted (`d.windowId === e.windowId`) is only in the extension's
"foreground guard": links a Claude tab's page opens in the foreground are reopened by the extension next to the
opener and grouped only when they land in its window. Those stay out of the group here (they open as child tabs of
the browser's own); Claude's own new tabs (`tabs_create_mcp`) compare no window ids and join the group (patch 3).

Checks: the E2E test `extensionTabsKeepTheirIds` runs Claude's session steps through the probe extension
(`windows.getLastFocused`, `tabs.create`, `tabs.get` a second later, `tabs.group`, `tabGroups.update`, then a second tab
opened in the group's window and joined to the group, `tabs.query({groupId})` holding both, `tabGroups.query` listing
the group once, and the `windows.create` fallback) with `BROWSER_E2E_CEF_PATCHES` listing 0006. Chrome's new-tab page,
which Claude's tabs start on, would contact Google: the CEF page shows the browser's own new tab instead (E2E
`chromesNewTabPageIsTheBrowsers`, runs today).

## Consequences

- Until our build has patches 1 and 2, Claude can act on tabs the user opened, and they land in the Claude space; a
  session that opens its own tab fails at its first step ("No tab with id").
- Built 2026-10-16: grouping the one tab of a page's tab strip works (`tabs.group`, `tabGroups.update`,
  `tabs.query({groupId})`), a tab opened by an extension opens as a child of the page in front, and a group holds
  tabs from several pages.
- The patches change how every extension's `tabs.create` behaves here, for the better (ids that last, the TODO's
  open item): they're tested with the extension suite (ExtensionAPITests), not only Claude's.
