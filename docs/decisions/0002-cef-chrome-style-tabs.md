# ADR-0002 — Real tabs in a Chrome-style CEF window (spike results, 2026-10-14)

Status: accepted. Amends ADR-0001 §1 ("tabs via the hidden TabStripModel").

## Experiment

A ~250-line Objective-C++ app against prebuilt CEF 154.0.34 (Chromium 154.0.8037.98), Chrome style,
`CefWindow` + `CefBrowserView`, toolbar `CEF_CTT_NONE`.

| Question | Result |
|---|---|
| Native NSView inside the CEF-owned window | ✅ `GetWindowHandle()` → `BridgedContentView`; window class `CefNSWindow`; adding a subview above the browser works |
| `ExecuteChromeCommand(IDC_NEW_TAB)` | ❌ opens a **separate stock Chromium window** (tab strip, omnibox, "Sign in to Chromium") via `GetDefaultClient()` — Views-hosted Chrome browsers are single-tab |
| Adding a 2nd Chrome-style `CefBrowserView` to a window that already hosted one | ❌ its browser is never created |
| Creating the view in a hidden **parking** `CefWindow`, then `RemoveChildView` there and `AddChildView` in the main window (after removing the current one) | ✅ browser created, moved, page `visibilitychange` → `visible` |
| Swapping views back and forth | ✅ detached views stay alive (page `hidden`), reattached view restores state (`visible`) |
| MV3 extension content script (`--load-extension`) | ✅ runs in every tab |
| `--disable-features=…` on the command line | ❌ crashes at startup (clobbers CEF's own list) — never override `disable-features` wholesale |
| `window.open` without user gesture | blocked (expected) |

## Decision

- **Engine `cef-chrome`**: one main `CefWindow` per browser window (Chrome style, frameless
  titlebar handled by us). Each tab = one Chrome-style `CefBrowserView`, created in a hidden parking
  window, then moved into the main window when presented. Inactive tabs are detached but alive;
  discarding closes them.
- Our SwiftUI shell is hosted in `NSHostingView`s added to the CEF window's content view; the
  browser view is inset with CEF Views layout (`CefPanel`/insets), never animated.
- Popups/new-tab requests (`OnBeforePopup`) are converted into our own tabs (so they join the tree)
  instead of letting Chrome open stock windows; `GetDefaultClient()` must route any Chrome-created
  browser back into our tab model.
- Each tab is its own Chrome `Browser` → extensions see one window per tab (`chrome.windows`).
  Acceptable trade-off; documented.
- Engine `webkit` is the second engine (fast to test, fork option). `cef-alloy` is deferred.
