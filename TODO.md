# TODO — feature inventory and progress

Every item comes from a reference the user gave. Sources: **R** = Radian / @oleksiibe
(`docs/research/radian-oleksiibe.md`), **H** = browser.horse, **A** = Arc
(`docs/research/horse-arc.md`), **B** = Brave, **U** = user's own requirement.

Status: `[ ]` todo · `[~]` in progress / partial · `[x]` done (has automated tests) ·
`[-]` intentionally excluded.

Rule (U): **every feature ships with automated tests** (unit and/or integration) that agents run
to check that the feature still works (`forkctl test <feature>`).

## 0. Foundation (U)
- [ ] Repo scaffold: `Core/`, `Shell/`, `Engines/`, `Features/`, `Defaults/`, `Tools/forkctl/`, `docs/`
- [ ] `forkctl generate`: scans `feature.yml` + `Fork/`, emits `Package.swift`, `project.yml`, registry, branding
- [ ] `forkctl validate` (ids, defaults, shortcut collisions, capability graph, brand literals, no cross-feature imports)
- [ ] `forkctl` verbs: init, rename, icon, feature add/remove/disable, engine use, test, sync, doctor
- [ ] Fork overlay `Fork/fork.yml` never touched upstream; merge-conflict-free customization
- [ ] Branding in one place (name, bundle id, URL scheme, UA brand, icon)
- [ ] AGENTS.md + per-feature README template + ADRs
- [ ] CI: build, unit tests, engine conformance suite, fork smoke test

## 1. Engines (U)
- [~] `cef-chrome`: Chrome-style CEF 154, SwiftUI overlay inside the CEF window, parked tabs (ADR-0002)
- [ ] CEF app bundle: 5 helpers, versioned framework layout, `CefAppProtocol`, signing
- [ ] `webkit`: WKWebView engine behind the same protocols (fork option, fast tests)
- [ ] Engine conformance test suite (navigation, title, favicon, find, zoom, popups, scripts)
- [ ] De-googled runtime defaults: no Google services/pings, switches + policies (U)
- [ ] Remote-CI recipe for a source build with ungoogled patches + H.264/AAC (U, documented)
- [-] `cef-alloy` engine (deferred; no extensions)

## 2. Sidebar & tabs
- [ ] Vertical sidebar: traffic lights, back/forward/reload, URL field inside the sidebar (A)
- [ ] Favorites grid (A, R) · Pinned tabs + nested folders (A) · Today tabs (A)
- [ ] **Tab tree**: links opened from a page become its children (H)
- [ ] Tree: collapse/expand, ⌘⇧←/→/↑/↓ navigation, ⌘W promotes children, ⌘⇧W deletes subtree, undo restores subtree (H)
- [ ] Tree: drag & drop reparent/reorder, ⌘⌥⇧ arrows move (H)
- [ ] Tree: URL dedup (focus existing), per-tab "open in place" toggle ⌘Y, domain exclusions (H)
- [ ] Focus mode (only current branch) ⌘⇧B (H) · Copy branch as Markdown (H)
- [ ] Link hover box (destination, title, "already open") (H, A)
- [ ] Instant hover hitbox + spring insert/close animations (R)
- [ ] Spaces with themes; two-finger swipe to switch with interactive spring (R, A)
- [ ] Auto-archive idle Today tabs (12 h default) + searchable archive (A)
- [ ] Tab discarding / hibernation (U perf)

## 3. Chrome & layout
- [ ] ⌘S hide sidebar → almost fullscreen; edge-hover reveals sidebar overlay (A, H shelf)
- [ ] Toolbar that hides on scroll down / shows on scroll up or top-edge hover (R)
- [ ] URL field position: sidebar or toolbar (R)
- [ ] Toasts while sidebar hidden ("New tab created") (A)
- [ ] Rounded, inset web content in a thin themed frame (A)
- [ ] Window dragging from empty sidebar space (A)

## 4. Command bar & keyboard (A, H, U)
- [ ] Command bar ⌘T: URL/search, open tabs, history, bookmarks, actions by name, site search (Tab), paste-and-go
- [ ] ⌘L edit current URL (in sidebar or centered bar)
- [ ] Full shortcut set (Arc + Horse tables), every action reachable from the keyboard
- [ ] Remappable shortcuts + "prefer website" (second press runs browser action) (A)
- [ ] Ctrl-Tab MRU switcher (A)
- [ ] Shortcut hints in tooltips/menus (A)

## 5. Browsing features
- [ ] Preview / Peek: links from pinned/favorites (or ⇧-click) open in an overlay (R, A)
- [ ] Mini window for external links (Little Arc) (A)
- [ ] Site controls popover: secure, camera, mic, sound, auto pop-out, site data size, permissions (R)
- [ ] Downloads: fly-to-toolbar animation + toast + panel (R) — [-] no AI renaming (U)
- [ ] Find in page, zoom, print, reader mode, devtools, view source (A, H)
- [ ] History panel ⌘Y (A, H) · Copy URL / as Markdown (A)
- [ ] Import from Arc, Atlas, Chrome, Dia, Helium, Safari (bookmarks, history, extensions) (R)
- [ ] Split view (A) — gated on engine capability, later
- [ ] Air Traffic Control link routing rules (A) — later
- [ ] Boosts (per-site CSS/JS) (A) — later

## 6. Apple integrations (R)
- [ ] Apple Passwords autofill via PasswordManagerBrowserExtensionHelper (needs entitlement)
- [ ] "Save Password?" into Apple Passwords
- [ ] Strong password generation **relying on Apple Passwords** (`SecCreateSharedWebCredentialPassword` + save in Passwords) (U)
- [ ] Sign in with Apple native sheet with Touch ID (AppSSO; needs entitlement)
- [ ] Passkeys via platform authenticator (needs entitlement)
- [ ] Touch ID gating (LocalAuthentication)
- [ ] Safari sync: favorites/bookmarks, iCloud Tabs, history — read side; write-back experimental (needs Full Disk Access)
- [ ] System-wide PiP: auto pop-out on tab switch, trackpad fling to corners, edge stash, custom controls, Meet call PiP

## 7. Privacy & ads (B, U)
- [ ] adblock-rust (Brave engine) via Rust staticlib + Swift bridge
- [ ] Brave default lists, cosmetic filtering, scriptlets
- [ ] Per-site allow toggle in site controls
- [ ] Creator-friendly mode: honour a site-declared ad policy (opt-in), "support creators" setting
- [ ] Security Core: log/inspect every outbound connection made by the browser itself; permission broker (R)

## 8. Extensions (U)
- [~] MV3 content scripts / background workers (spike ✅)
- [ ] Load unpacked + Chrome Web Store install
- [ ] Native extension buttons + popups in the sidebar/toolbar
- [ ] `chrome://extensions` management reachable from settings

## 9. Performance (U)
- [ ] Paint shell before engine init; lazy feature activation
- [ ] Budgets: app process < 150 MB (excl. renderers); 500-tab model < 20 MB; switch tab < 16 ms
- [ ] Perf regression tests (signposts)
