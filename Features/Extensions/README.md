# Extensions

**Purpose** — Chrome extensions from the sidebar: pinned extension buttons and the extensions menu next to the
navigation buttons. Popups, permission prompts, pinning, site access and options pages are Chrome's own UI, so
extensions behave exactly as in Chrome (popups, `action.onClicked`, badges' actions, the `activeTab` grant).

**How it works** — The engine implements `EngineExtensions` (Core). On Chromium, every page carries Chrome's real
toolbar in an invisible 1×1 overlay; actions are pressed through it, and Chrome anchors popups to its (virtual)
buttons at the page's top-left, beside the sidebar. See `docs/decisions/0003-hidden-chrome-toolbar.md`.
Engines without extensions (WebKit) get no buttons and the commands do nothing.

**Commands**
- `extensions.menu` — Extensions… (cmd+shift+e)
- `extensions.run` — runs one extension's action (argument `id`; automation and other features)
- `extensions.manage` — Manage Extensions (`chrome://extensions`, where "Load unpacked" lives)
- `extensions.store` — Chrome Web Store

**Settings**
- `extensions.showPinned` — Show pinned extensions in the sidebar

**Engine option** — `"engineOptions": { "chromeToolbar": "none" }` drops the hidden toolbar (no actions).

**Tests** — `./forkctl test extensions`; end to end: `EngineConformanceTests.extensionActionGetsActiveTab`.

**Remove it** — `./forkctl feature disable extensions` (extensions keep running; only the buttons go).
