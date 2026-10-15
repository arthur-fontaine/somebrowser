# TODO — feature inventory and progress

Every item comes from a reference the user gave. Sources: **R** = Radian / @oleksiibe
(`docs/research/radian-oleksiibe.md`), **H** = browser.horse, **A** = Arc
(`docs/research/horse-arc.md`), **B** = Brave, **U** = user's own requirement.

Status: `[ ]` todo · `[~]` in progress / partial · `[x]` done (has automated tests) ·
`[-]` intentionally excluded.

Rule (U): **every feature ships with automated tests** (unit and/or integration) that agents run
to check that the feature still works (`forkctl test <feature>`).

## 0. Foundation (U)
- [x] Repo scaffold: `Core/`, `Shell/`, `Engines/`, `Features/`, `Defaults/`, `Tools/forkctl/`, `docs/`
- [x] `forkctl generate`: scans `feature.json` + `Fork/`, emits `Package.swift`, registry, branding, `main.swift`
- [x] `forkctl validate` (ids, defaults, shortcut collisions, capability graph, brand literals, no cross-feature imports)
- [x] `forkctl` verbs: init, rename, icon, feature add/remove/disable, engine use, test, sync, doctor
- [x] Fork overlay `Fork/fork.json` never touched upstream; merge-conflict-free customization
- [x] Branding in one place (name, bundle id, URL scheme, UA brand, icon)
- [x] AGENTS.md + per-feature README template + ADRs
- [x] CI: `./forkctl ci` — validate, every unit test (forkctl's too), the E2E suite on every engine, and a fork smoke test
      (rename, engine swap, feature off/new, shortcut, setting on a copy: builds, and only `Fork/` changes). No git remote
      here, so no hosted workflow yet; a hosted Mac needs Chromium-sized disk for the CEF E2E
- [ ] Rare CEF quit flake in E2E (1 of ~200 launches, 2026-10-15): after `quit` the app idles in its run loop, shutdown
      apparently never starts (AppDriver's timeout sample); not reproduced in 5 reruns of the test

## 1. Engines (U)
- [x] `cef-chrome`: Chrome-style CEF 154, page child windows + shell overlay window (ADR-0002); real clicks, typing, tree, clean quit verified
- [x] CEF app bundle: 5 helpers, versioned framework layout, `CefAppProtocol`, ad-hoc signing (`forkctl build`)
- [x] `webkit`: WKWebView engine behind the same protocols (fork option, fast tests)
- [x] Engine conformance test suite: `./forkctl test --e2e` (Chromium + WebKit, `FORKCTL_ENGINE=…`)
- [x] De-googled runtime defaults: an idle profile contacts no third party (E2E net-log test); extension updates kept
- [x] Chrome's default search engine follows the `search` feature's engine (context menu "Search for…"); idle net log clean
- [-] Silence the `ListAccounts` retries to the dead loopback endpoint: measured 2026-10-15, five instant failures at
      startup with backoff (0–38 s), then none; `signin.allowed=false` doesn't stop them — not worth more
- [x] Recipe for a source build with ungoogled patches + H.264/AAC (`docs/recipes/ungoogled-cef.md`; forks pin their build
      in `Fork/Engines/CEF/vendor.json`) — the build itself not run here yet (needs a large Mac) (U)
- [-] `cef-alloy` engine (deferred; no extensions)

## 2. Sidebar & tabs
- [x] Vertical sidebar: traffic lights, back/forward/reload, URL field inside the sidebar (A)
- [x] Favorites grid (A, R) · Pinned tabs + nested folders (A) · Today tabs (A)
- [x] **Tab tree**: links opened from a page become its children (H)
- [x] Tree: collapse/expand, ⌘⇧←/→/↑/↓ navigation, ⌘W promotes children, ⌘⇧W deletes subtree, undo restores subtree (H)
- [x] Tree: drag & drop reparent/reorder, ⌘⌥⇧ arrows move (H)
- [x] Tree: URL dedup (focus existing), per-tab "open in place" toggle ⌘Y, domain exclusions (H)
- [x] Focus mode (only current branch) ⌘⇧B (H) · Copy branch as Markdown (H)
- [x] Link hover box (destination, title, "already open") (H, A)
- [x] Instant hover hitbox + spring insert/close animations (R)
- [x] Spaces with themes; two-finger swipe to switch with interactive spring (R, A)
- [x] Auto-archive idle Today tabs (12 h default) + searchable archive (A)
- [x] Tab hibernation: idle background tabs (default 1h) and memory pressure; woken tabs keep back/forward (U perf)

## 3. Chrome & layout
- [x] ⌘S hide sidebar → almost fullscreen; edge-hover reveals sidebar overlay (A, H shelf)
- [x] Toolbar that hides on scroll down / shows on scroll up or top-edge hover (R)
- [x] URL field position: sidebar or toolbar (R)
- [x] Toasts while sidebar hidden ("New tab created") (A)
- [x] Rounded, inset web content in a thin themed frame (A)
- [x] Window dragging from empty sidebar space (A)

## 4. Command bar & keyboard (A, H, U)
- [x] Command bar ⌘T: URL/search, open tabs, history, bookmarks, actions by name, site search (Tab), paste-and-go
- [x] ⌘L edit current URL (in sidebar or centered bar)
- [x] Full shortcut set (Arc + Horse tables), every action reachable from the keyboard: console ⌥⌘J, inspect ⌥⌘C, save
      ⇧⌘S, ⇧⌘I, ⇧⌘H, sidebar undo/redo ⌘Z/⇧⌘Z (typing first), Capture ⇧⌘2, next pinned extension ⌘E, developer mode ⌃D
- [x] Remappable shortcuts + "prefer website shortcuts" (page first; browser on a second press or if unused) (A)
- [x] Ctrl-Tab MRU switcher (A)
- [x] Shortcut hints in tooltips/menus (A)

## 5. Browsing features
- [x] Preview / Peek: links from pinned/favorites (or ⇧-click) open in an overlay (R, A)
- [x] Mini window for external links (Little Arc) (A)
- [x] Site controls popover: secure, camera, mic, sound, auto pop-out, site data size, permissions (R)
- [x] Downloads: fly-to-toolbar animation + toast + panel (R) — [-] no AI renaming (U)
- [x] Find in page, zoom, devtools, view source · print (native panel) · reader mode (Readability, ⌥⌘R) (A, H)
- [x] History panel ⌘Y (A, H) · Copy URL / as Markdown (A)
- [~] Import from Arc, Atlas, Chrome, Dia, Helium (+ Brave, Edge, Vivaldi): bookmarks → pinned folder, history,
      Web Store extensions with one-click Add — verified with this Mac's Chrome profiles. Safari (via the Safari feature's grants) done; Arc's
      Spaces' pinned tabs from `StorableSidebar.json` (format per arc-export, tested with a fixture: no Arc sidebar here to
      check); Atlas path is community-reported (R)
- [x] Split view: two tabs side by side (⌃⇧= / ⌃⇧] / ⌃⇧-), pane in the `content-trailing` slot; engines let a page belong to
      one viewport at a time (A)
- [x] Air Traffic Control: rules route links from other apps to a Space, a mini window or the main window (A)
- [x] Boosts: per-site CSS (before first paint), JavaScript, zapped elements; editor + site-controls row (A)

## 6. Apple integrations (R)
- [~] Apple Passwords autofill via PasswordManagerBrowserExtensionHelper — `passwords` feature: SRP pairing (verified
      against an independent reference), dropdown, Touch ID fill; tested against a fake helper. Live use needs a build
      signed with the managed entitlement (ad-hoc builds are refused by a launch constraint, verified)
- [~] "Save Password?" into Apple Passwords (command 6; same entitlement gate)
- [~] Strong password generation **relying on Apple Passwords** (`SecCreateSharedWebCredentialPassword` + save in Passwords) (U)
- [~] Sign in with Apple native sheet with Touch ID — `apple-signin` feature: AppSSO interception, in-window sheet,
      response loaded with appleid.apple.com's origin (`loadSimulated`, both engines). AppSSO declines unentitled
      builds (verified), and the web flow continues; the native sheet needs a signed, entitled build
- [~] Passkeys via platform authenticator: Chromium uses `ASAuthorizationWebBrowserPublicKeyCredentialManager` by itself
      once the build carries the entitlement — no code of ours; verify with a signed build
- [x] Touch ID: the system's own prompts inside Apple Passwords (helper) and Sign in with Apple (AppSSO), as in the tweets
- [x] Safari sync without Full Disk Access (two open-panel grants), checked with real data and the user's iPhone
      (2026-10-15):
      - **Favorites, both ways.** Add and delete are written through Safari's change log and lock, then Safari is asked
        to upload.
      - **iCloud Tabs, iPhone to here only.** This browser's tabs can't join iCloud Tabs: only Safari can hand tabs to
        its agent (entitled XPC).
      - **Tab Groups.** Safari's are shown here. This browser's own tabs go to the iPhone as a Tab Group named after the
        Mac, written by WebBookmarks itself; adding and removing were seen on the iPhone.
      - **History, both ways.** Safari's appears in the command bar. Visits from here go into History.db, and one
        uploaded at Safari's launch.
      - **Upload timing.** Uploads need Safari to sync. When Safari isn't running, it's launched hidden and quit after.
      - **Still open:** the full loop inside the app, and the user's first look at the KRAAFT-ARTHUR-F group.
- [x] System-wide PiP: auto pop-out on tab switch, trackpad fling to corners, edge stash, custom controls, Meet call PiP

## 7. Privacy & ads (B, U)
- [x] adblock-rust (Brave engine) via Rust staticlib + C API crate (`forkctl` builds `"cargo"` crates); real lists verified in the app
- [x] Brave default lists, cosmetic filtering (page-specific + generic), URL cleaning — scriptlets at document start and redirect stand-ins (uBO + Brave resources; YouTube rules verified live)
- [x] Per-site allow toggle in site controls (with blocked counter)
- [x] Creator-friendly mode: sites declaring Web Monetization keep their ads ("support creators", on by default); trackers stay blocked
- [x] Security Core: every connection the browser makes by itself goes through Core's `OutboundConnections` (validator:
      no URLSession in features/engines), cookieless, logged (no query strings; private windows not logged), shown with
      the permission broker's log in Tools ▸ Security Core (R). Chromium's own requests aren't observable through CEF:
      the panel says so

## 8. Extensions (U)
- [x] MV3 content scripts / background workers (E2E: content script ↔ service worker messaging and storage)
- [x] Chrome Web Store install (uBlock Origin Lite: install dialog, blocking, auto-update verified)
- [x] Load unpacked: `--load-extension` (E2E fixtures); developer mode's "Load unpacked" on `chrome://extensions` opens the native
      directory picker (verified 2026-10-15)
- [x] Extension actions + popups via an invisible Chrome toolbar (ADR-0003): pinned buttons + menu in the sidebar,
      Chrome's own popups/permissions, `activeTab` proven by E2E (`extensionActionGetsActiveTab`)
- [ ] Badges on the sidebar buttons — not in the toolbar's accessibility tree (checked: a pinned action exposes only its
      name); needs a source-build patch exposing ExtensionAction badge text to CEF
- [ ] Drop the hidden omnibox's AI-mode popup renderer (~50 MB shared, one `chrome://omnibox-popup.top-chrome/omnibox_popup_aim.html`
      per tab, ADR-0003): not gated by the features AiMode, AllowAiModeMatches, WebUIOmniboxFullPopup, OmniboxEverywhereComposebox,
      ShowAiModeAction*, WebUIOmniboxDynamicAiModeButton, OmniboxPopupButton nor the prefs omnibox.ai_mode_settings=1 /
      omnibox.show_ai_mode_omnibox_button=false (checked 2026-10-15); patch it in a source build
- [x] `chrome://extensions` management reachable (Tools menu, command bar: `extensions.manage`)
- [x] API compatibility probe (E2E `ExtensionAPITests`, matrix in the Extensions README): scripting, offscreen, web auth
      flow, tabs, commands, DevTools panels pass; notifications show (Chromium popups)
- [x] Side panels: hosted in a pane beside the content (Chrome draws them in window chrome pages here don't have)
- [x] New tab page overrides get ⌘T / New Tab (setting `extensions.newTabPage` keeps the command bar)
- [x] DevTools keep their own window (they were adopted as a disconnected tab) with extension panels
- [x] `chrome.tabs.remove` closes the tab (the page closed, the tab stayed in the sidebar)
- [x] Real extensions: 16 checked (README), the last 10 together with no errors in chrome://extensions; Vimium's
      in-page keys work, its tab keys don't (window model)
- [ ] `tabs.create` with no live page fails ("No current window"): install welcome pages are lost in an empty window
- [ ] `tabs.create`/`windows.create` ids that last, one Chrome window per browser window, `downloads.download` from
      service workers — CEF hosts each page as its own popup-type Chrome window and cancels page-less downloads: patch
      CEF in the source build
- [-] `omnibox` keywords: the command bar replaces Chrome's omnibox; CEF can't hand it input
- [x] Checked: `window.focus()` in a background tab (app in front or not) leaves no page window detached from the browser
      window; the one seen came from DevTools being adopted as a tab (fixed)

## 9. Performance (U)
- [x] Lazy feature activation (heavy work deferred) · [-] paint shell before CEF init: measured 2026-10-15, warm launch
      shows the window at ~350–450 ms and CEF initialization is ~80 ms of it — not worth windows before the run loop
- [x] Budgets: app process < 150 MB (excl. renderers; ~110 MB); 500-tab model < 20 MB (~0.7 MB); switch tab < 16 ms (~6 ms)
- [x] Perf regression tests: budgets checked in E2E (both engines) and Core tests
