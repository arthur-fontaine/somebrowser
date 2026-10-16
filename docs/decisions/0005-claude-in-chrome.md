# 0005 — Claude in Chrome: what works today, and the patches for the rest

Date: 2026-10-16 · Status: proposed (the patches below aren't written or built yet)

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

1. **Chrome's new tabs keep their ids (CEF).** CEF already hosts popups a page opens directly in a views browser of
   ours (`OnPopupWebContentsCreated` → `CreateBrowserHostForPopup` → `OnPopupBrowserViewCreated`), keeping their
   WebContents and so their tab id. A tab Chrome makes without an opener goes through
   `ChromeBrowserDelegate::SetAsDelegate` into a stock Browser instead. Patch: when that stock Browser would be made
   for a new tab (extension `tabs.create`, `windows.create`, `IDC_NEW_TAB`) and a views-hosted CEF browser exists,
   route the WebContents through the popup path with that browser as opener (`popup_with_views_hosted_opener`). The
   app then adopts it in `OnPopupBrowserViewCreated`, as it does page popups, and the id lasts. The anchor window
   (`CEFRuntime updateAnchor`) is the opener while no page is open.
2. **Page windows are `normal` windows (CEF).** Create the Browser of a views-hosted Chrome-style page with
   `TYPE_NORMAL` when its toolbar is `CEF_CTT_NORMAL` (ours always is), so `windows.getLastFocused({windowTypes:
   ["normal"]})` finds the window in front, and `tabs.create({windowId})` lands in it (then patch 1 makes it a tab of
   ours).
3. **Groups across page windows (Chromium).** One window per tab means a group can't hold several tabs. Patch
   `TabsGroupFunction`/`TabGroupsUpdateFunction`/`tabs.query({groupId})` behind a switch (`--groups-across-windows`)
   so a group is a set of tab ids the browser keeps (not a tab strip span): grouping never moves tabs, `groupId` on
   each tab reports it, and `tabGroups.onCreated/onUpdated/onRemoved` fire as usual. The app reads the groups (CEF
   API `CefBrowserHost::GetTabGroupId`, new) and puts a Claude group's tabs in the Claude space directly, without
   waiting for the page marks.

Order: 1 and 2 make Claude Code work end to end with a single tab per session; 3 makes multi-tab sessions work.
Each needs a build (about 3 hours on the build Mac) and the E2E check `claudeCodeDrivesTheBrowser` (a fixture
extension doing what Claude's does: `windows.getLastFocused`, `tabs.create`, `tabs.group`, `tabs.update` by id).

## Consequences

- Until the patches, Claude can act on tabs the user opened, and they land in the Claude space; a session that opens
  its own tab fails at its first step ("No tab with id").
- The patches change how every extension's `tabs.create` behaves here, for the better (ids that last, the TODO's
  open item): they're tested with the extension suite (ExtensionAPITests), not only Claude's.
