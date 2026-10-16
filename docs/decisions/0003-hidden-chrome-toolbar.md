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

- the toolbar is the content of a 1×1 `CefScrollView` (a scroll view because layouts squeeze children to the
  host's size, and Chrome then lays the toolbar out at its minimum and hides pinned actions); views clip to
  the viewport, so nothing is visible and the page receives every click. Its virtual width is 560 pt + 40 pt
  per pinned action: below ~560 pt Chrome folds pinned actions into its menu;
- anchors keep their unclipped screen bounds, so Chrome's bubbles (extensions menu, popups, install and
  permission prompts) open where the virtual buttons are and, being children of the overlay window, above the
  page. The toolbar ends at the page's top-right corner, where Chrome users expect popups (overlays can't
  start left of the page, so the buttons can't sit beside the sidebar);
- the sidebar's buttons press Chrome's buttons through in-process accessibility (`accessibilityPerformPress`).
  The extensions container is found by structure (the group ending with a pop-up button and holding no text
  field), never by localized labels. Pinned actions are pop-up buttons labelled "<name>\n<site access>";
  unpinned ones go through Chrome's own extensions menu.

The list of installed extensions comes from the profile (`Secure Preferences` → `extensions.settings`,
`Preferences` → `extensions.pinned_extensions`, `_locales`, manifests on disk for unpacked extensions), re-read
when Chrome replaces those files.

## Consequences

- Extensions behave as in Chrome; the E2E test `extensionActionGetsActiveTab` proves the `activeTab` grant.
- Cost: ~1 MB per tab in the browser process, after hiding Chrome's other toolbar buttons and disabling
  `PreloadTopChromeWebUI` / `WebUIOmniboxPopup` (each would preload a WebUI renderer). One fixed renderer
  remains: the hidden omnibox's AI-mode popup (`chrome://omnibox-popup.top-chrome/omnibox_popup_aim.html`),
  46 MB footprint for the whole app; `AimEnabled`, `OmniboxDuiPrerendering` and related flags don't stop it.
- Keyboard: Tab never leaves the page for the toolbar, and ⌘L is ours (the command bar); verified manually.
- Every extension is pinned in the hidden toolbar (the engine writes Chrome's `extensions.pinned_extensions` before
  launch), so each action has its own button and the browser's Extensions panel replaces Chrome's menu; the sidebar's
  pins are the browser's own list (2026-10-16).
- Clicks: `AddOverlayView` also adds an empty view above the page, the overlay's z-order reference, and the window's
  fill layout stretches it over the whole page. Chromium routes a click to the page only when its views put the
  page under the pointer, so that view took every click (2026-10-16, CEF 154 and 156). The page's view is moved
  back on top after the overlay is added; E2E `clicksReachThePage` covers it.
- The installed list lags Chrome by its preference write interval (~10 s). An extension installed since launch is
  pinned live (Chrome follows `extensions.pinned_extensions`), so actions don't go through Chrome's menu.
- The page is made key before its action runs: Chrome puts what the extension asks for (a permission prompt…) over its
  active window, else over its newest page window, maybe a hidden tab's (with the sidebar key) (2026-10-16).
- Teardown: Chrome's browser view keeps a pointer to its toolbar, so before a page window closes the toolbar
  is moved back into that window (hidden) and the overlay destroyed; otherwise the toolbar dies with the
  overlay widget first and closing the window is a use-after-free. E2E quits fail on any crash.
- Rejected: a reserved toolbar row (costs the "almost fullscreen" layout); ordering the overlay below the page
  (Chrome's bubbles then need re-parenting, and non-key bubbles stay hidden).
- Forks: `"engineOptions": { "chromeToolbar": "none" }` removes the toolbar (no actions, menu falls back to
  `chrome://extensions`).
