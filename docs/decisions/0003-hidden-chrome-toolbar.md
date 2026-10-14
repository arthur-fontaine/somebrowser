# ADR-0003 — Extension actions through an invisible Chrome toolbar

Status: accepted (2026-10-14)

## Context

Chrome extensions are reached through their toolbar action: popups, `action.onClicked`, badges and — most
importantly — the `activeTab` grant all go through Chrome's `ExtensionsToolbarContainer`. Our pages are
Chrome-style browser views without a toolbar (ADR-0002), and the sidebar replaces Chrome's toolbar.

Loading `chrome-extension://<id>/popup.html` in our own window would show popups, but `onClicked`-only
extensions would do nothing and `activeTab` would never be granted ("Remove an element", page tools…). There is
no public API for native code to run another extension's action.

## Decision

Each page's `CefBrowserView` asks for `CEF_CTT_NORMAL`. Once the view is in its window, Chrome's toolbar view is
moved into an overlay (`CefWindow::AddOverlayView`, custom docking) that is **1×1 points**:

- the toolbar sits in a fixed-width inner panel (360 pt + 40 pt per pinned action) inside a 1×1 clip panel;
  views clip children to their parent, so nothing is visible and the page receives every click;
- anchors keep their unclipped screen bounds, so Chrome's bubbles (extensions menu, popups, install and
  permission prompts) open where the virtual buttons are — the page's top-left corner, next to the sidebar
  buttons — and, being children of the overlay window, above the page;
- the sidebar's buttons press Chrome's buttons through in-process accessibility (`accessibilityPerformPress`).
  The extensions container is found by structure (the group ending with a pop-up button and holding no text
  field), never by localized labels. Unpinned actions go through Chrome's own extensions menu.

The list of installed extensions comes from the profile (`Secure Preferences` → `extensions.settings`,
`Preferences` → `extensions.pinned_extensions`, `_locales`, manifests on disk for unpacked extensions), re-read
when Chrome replaces those files.

## Consequences

- Extensions behave as in Chrome; the E2E test `extensionActionGetsActiveTab` proves the `activeTab` grant.
- Cost: ~1 MB per tab in the browser process, after hiding Chrome's other toolbar buttons and disabling
  `PreloadTopChromeWebUI` / `WebUIOmniboxPopup` (each would preload a WebUI renderer).
- Keyboard: Tab never leaves the page for the toolbar, and ⌘L is ours (the command bar); verified manually.
- The installed list lags Chrome by its preference write interval (~10 s).
- Teardown: Chrome's browser view keeps a pointer to its toolbar, so before a page window closes the toolbar
  is moved back into that window (hidden) and the overlay destroyed; otherwise the toolbar dies with the
  overlay widget first and closing the window is a use-after-free. E2E quits fail on any crash.
- Rejected: a reserved toolbar row (costs the "almost fullscreen" layout); ordering the overlay below the page
  (Chrome's bubbles then need re-parenting, and non-key bubbles stay hidden).
- Forks: `"engineOptions": { "chromeToolbar": "none" }` removes the toolbar (no actions, menu falls back to
  `chrome://extensions`).
