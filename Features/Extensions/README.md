# Extensions

**Purpose** — Chrome extensions from the sidebar: the extensions you chose show as buttons next to the navigation
buttons, and the Extensions panel (⌘⇧E, the puzzle button) lists them all: run one, show it in the sidebar or not, its
options and side panel. The panel is the browser's own; Chrome's extensions menu never shows. Popups, permission
prompts and options pages are the extensions' (or Chrome's), so extensions behave as in Chrome (popups,
`action.onClicked`, the `activeTab` grant); Manage Extensions… opens Chrome's page for site access and removal.

**How it works** — The engine implements `EngineExtensions` (Core). On Chromium, every page carries Chrome's real
toolbar in an invisible 1×1 overlay where every extension is pinned (the engine pins them all in Chrome's preferences
before launch; one installed meanwhile goes through Chrome's menu, unseen behind the overlay, until the next launch).
Which ones show in the sidebar is the browser's own list (`sidebar-extensions.json` in the engine profile, taken from
Chrome's pins the first time). Actions are pressed through the hidden toolbar, and Chrome anchors popups to its (virtual)
buttons at the page's top-left, beside the sidebar. See `docs/decisions/0003-hidden-chrome-toolbar.md`.
Engines without extensions (WebKit) get no buttons and the commands do nothing.

**Commands**
- `extensions.menu` — Extensions… (cmd+shift+e): the browser's Extensions panel
- `extensions.run` — runs one extension's action (argument `id`; automation and other features)
- `extensions.cycle` — Next Pinned Extension (⌘E, Arc): each press runs the next pinned one
- `extensions.manage` — Manage Extensions (`chrome://extensions`, where "Load unpacked" lives)
- `extensions.store` — Chrome Web Store
- `extensions.side-panel` — Extension Side Panel (argument `id`; else the open or last used panel)

**Settings**
- `extensions.showPinned` — Show pinned extensions in the sidebar
- `extensions.newTabPage` — Open new tabs on an extension's new tab page (instead of the command bar)

**Capabilities** — provides `new-tab-page` (`NewTabPageProvider`): the command bar asks it before opening for ⌘T.

**Engine option** — `"engineOptions": { "chromeToolbar": "none" }` drops the hidden toolbar (no actions).

**Tests** — `./forkctl test extensions`; end to end: `EngineConformanceTests.extensionActionGetsActiveTab` (popup
with activeTab, pinned and from the menu), `contentScriptsTalkToTheirWorker` (MV3 content script ↔ service worker), and
`ExtensionAPITests`, where a probe extension (`Tests/Fixtures/ApiProbeExtension`) runs the APIs whose plumbing differs
here from Chrome's: scripting, offscreen documents, the web auth flow, `tabs.update`/`tabs.create`, the side panel, the
new tab page, DevTools panels and keyboard shortcuts.

**Compatibility** (Chromium engine, 2026-10-15). Pages here are Chrome browsers in windows of their own, without
Chrome's window chrome (tab strip, side panel, omnibox), which decides what differs:
- *As in Chrome:* content scripts, service workers, messaging, storage, `scripting`, offscreen documents,
  `identity.launchWebAuthFlow` (Chrome's own sign-in window), `tabs.update`, `tabs.remove`, declarative net requests, popups and
  `action.onClicked`, `activeTab`, options pages, keyboard shortcuts (`commands`), DevTools panels (`devtools_page`),
  notifications (Chromium's own popups), downloads started from extension pages open in tabs.
- *Hosted by the browser:* side panels open in a pane beside the content (one per window), from the extension's button
  when it asked for that (`openPanelOnActionClick`) or View ▸ Extension Side Panel; a `sidePanel.open()` call from the
  extension itself shows nothing. A new tab page override gets ⌘T and New Tab (`extensions.newTabPage` keeps the
  command bar).
- *Different:* every tab is a Chrome window of its own (type `popup`, one tab), so `windows.getAll` lists one window per
  tab, `tabs.query({ currentWindow: true })` returns only the current tab and `tabs.query({ active: true })` every tab.
  The current tab (`{ active: true, currentWindow: true }`) follows the selected tab once its page has had keyboard
  focus. `tabs.create` and `windows.create` (`popup` or `normal`) open a tab of the browser window, but Chrome first
  makes the page in a window of its own, which the browser closes and reopens as a tab: the tab or window id the
  extension gets back is gone at once (`tabs.get`, `tabs.sendMessage`, `windows.get` on it fail), which matters to
  extensions that keep a pop-out window and close it later. With no page open (an empty window, a first launch),
  Chrome would have no window to start from ("No current window", so welcome pages opened on install were lost):
  while extensions are installed, the engine keeps a page-less window that is never shown until a page opens. It
  costs ~9 MB and no renderer, and extensions see it as one blank tab then. After a first launch it's made 2 s after
  startup, if no page was restored: made first, it delayed the restored page by ~150 ms. Commands that work on "the tabs of this
  window" see one tab: Vimium's in-page keys work, its tab keys (`J`/`K`, `x`) do nothing (the browser's own
  shortcuts switch and close tabs).
- *Not working:* `downloads.download` from a service worker or popup (CEF cancels downloads tied to none of its pages;
  `libcef/browser/download_manager_delegate_impl.cc`), `omnibox` keywords (the command bar replaces Chrome's omnibox and
  CEF can't hand it input), badges on the sidebar buttons. The first and keeping `tabs.create` ids need a patched CEF.
- *Not checked:* `contextMenus` items (they go into Chrome's own context menu; not automated).

**Checked with real Web Store extensions** (2026-10-15, Chromium engine, loaded unpacked from the store's packages):
Bitwarden 2026.9.3 (service worker, popup through its toolbar action), uBlock Origin Lite 2026.1012 (declarative
network rules blocked an ad request with the built-in blocker off), Dark Reader 4.9.133 (content scripts restyled the
page). Store installs and updates were checked earlier with the Web Store's one-click Add. Then Momentum 2.27.8 (its
new tab page on ⌘T), Sider 5.35.0 (its side panel in the pane, its content script's button on pages, its welcome tab
from `tabs.create`) and OneTab 2.24 (its popup, Chrome's prompt for the extra permission it asks for there, its help tab
from `tabs.create`). Then, loaded together, all enabled with no manifest or runtime errors in `chrome://extensions`
(service workers running, MetaMask's offscreen document too): Vimium 2.4.2 (`j`, `G`, `gg` scroll, `t` opens its new
tab; `J`/`K`/`x` don't, see above), Privacy Badger 2026.9.15.2 (its welcome page), MetaMask 13.52.0.0, Violentmonkey
2.49.0, React Developer Tools 8.0.0, Grammarly 14.1338.0, Google Translate 2.0.17, JSON Formatter 0.10.2, Proton Pass
1.42.0, Return YouTube Dislike 4.0.5 (their own features need accounts or sites not tried here).

**Remove it** — `./forkctl feature disable extensions` (extensions keep running; only the buttons go).
