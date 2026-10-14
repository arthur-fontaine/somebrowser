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

## Follow-up experiment: what extensions see

| Check | Parked views moved into one window | **Child-window composition** |
|---|---|---|
| `chrome.tabs.query({active, lastFocusedWindow})` after a switch | ❌ still the detached tab (each `Browser` stays bound to the window it was created in) | ✅ follows our switch |
| `chrome.tabs.create()` from a background worker | 💥 main process crash | ✅ works, but opens a stock Chromium window (`BrowserNativeWidgetWindow`) via `GetDefaultClient()` |
| Tab switch latency | ~1 ms | ~1.5 ms (50 switches in 77 ms) |
| Shell window key state while the page has focus | n/a | shell not key, tab window key → shell needs an "active appearance" override |

Memory baseline (RSS sum, shared pages double counted): 2 tabs + `chrome://extensions` ≈ 828 MB
(10 processes); 3 tabs + 1 extension + 1 stock window ≈ 1.37 GB (19 processes).

## Decision

- **Engine `cef-chrome` uses child-window composition.** The shell `NSWindow` is ours (SwiftUI,
  native titlebar, vibrancy, animations). Each tab is a frameless Chrome-style `CefWindow` with one
  `CefBrowserView` (toolbar `CEF_CTT_NONE`), attached with `addChildWindow(_:ordered:)` over the
  content rect. Switching tabs = attach/order-front the next child, detach/order-out the previous
  one, make it key. Chrome's model stays consistent (one `Browser` per tab).
- The shell window subclass reports an active appearance while one of its tab windows is key.
- Child frames are updated synchronously on shell resize; children have no shadow and are clipped
  to the rounded content shape.
- Browsers Chrome creates on its own (extension `chrome.tabs.create`, `IDC_NEW_TAB`, …) arrive via
  `GetDefaultClient()` without a `CefBrowserView`: we **adopt** them (close the stock window, reopen
  the URL as one of our tabs, parented in the tree). Documented limitation: the extension sees the
  original tab id close.
- Popups from pages (`OnBeforePopup`) are created directly as our tabs (children in the tree).
- Each tab is its own window to extensions (`chrome.windows.getAll()` returns N).
- Engine `webkit` hosts `WKWebView`s directly in the shell window. `cef-alloy` is deferred.
