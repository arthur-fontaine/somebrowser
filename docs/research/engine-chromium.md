# Chromium engine options on macOS (researched 2026-10-14)

## Hard constraints (verified against CEF headers / issues)

- Local Chromium/CEF source builds are out of reach on this machine: CEF docs ask for ~150 GB free
  for a debug build and ~4 h; we have ~110 GB. Source builds must happen on remote CI later.
- Prebuilt CEF: `cef-builds.spotifycdn.com/index.json`. Latest stable
  `154.0.34+g14c5a08+chromium-154.0.8037.98` (2026-10-05), macosarm64 minimal = 132 MB tarball,
  framework 322 MB on disk. BSD-3. Xcode 26+ needs a versioned framework layout.
- `include/internal/cef_types_mac.h`: *"Alloy style will always be used if
  windowless_rendering_enabled is true or if parent_view is provided."* — so a CEF browser inside
  **our own NSView** is always Alloy style on macOS.
- `cef_types_runtime.h`: Chrome style needs CEF Views (`CefWindow` + `CefBrowserView`); *"a Chrome
  style Window can host at most one Chrome style BrowserView but potentially multiple Alloy style
  BrowserViews"*.
- CEF #3685: *"The Chrome extension API is supported with Chrome style browsers/windows only."*
  Alloy style supports only the extension APIs needed by built-in components (PDF viewer).
- Chrome style keeps Chrome's `Browser` + `TabStripModel` per window (see
  `libcef/browser/chrome/chrome_browser_delegate.cc`: WebContents can move between Browsers;
  each tab has its own CefBrowser host). Tab strip is hidden in Views-hosted mode; tabs can be
  driven with `CefBrowserHost::ExecuteChromeCommand(IDC_…)`.
- No programmatic extension-management API in CEF (#3450 open). `chrome://extensions` works in
  Chrome style. Chrome Web Store install in CEF: unverified, plausible (Chromium chrome layer).
- Prebuilt CEF has **no H.264/AAC** (proprietary codecs off, #3559). Fix = source build with
  `proprietary_codecs=true ffmpeg_branding=Chrome` (licensing exposure).
- CEF executables load the framework dynamically (`cef_library_loader.h`); the app needs 5 helper
  bundles: Helper, Helper (Alerts), Helper (GPU), Helper (Plugin), Helper (Renderer). Principal
  class must implement `CefAppProtocol` (`isHandlingSendEvent`/`setHandlingSendEvent:`).

## Hosting modes

| Mode | Native feel | Extensions | Notes |
|---|---|---|---|
| Alloy, child NSView (`SetAsChild`) | Best: we own window + views | Only built-in | Real per-tab CefBrowser; easy to animate/reparent |
| Alloy, off-screen (IOSurface → CALayer) | Good, but we forward all input/IME/a11y | Only built-in | Extra cost |
| Chrome style, CEF-owned NSWindow + SwiftUI overlay ("inverted ownership") | Good: still a real NSWindow we can style | Full (MV3, chrome://extensions) | One Chrome-style BrowserView per window; tabs via hidden TabStripModel; no extension toolbar UI (we must build it) |

## De-googling

- No prebuilt de-googled CEF exists. Proven recipe: `nmlynch94/com.adamcake.ungoogled_cef.BaseApp`
  (CEF 139 + ungoogled-chromium patches + `ungoogled-chromium-adjust-for-cef.patch`; also needs CEF
  `gn_args.py` patches for `enable_widevine/enable_rlz`).
- Helium (imputnet, GPL-3.0) publishes ~370 quilt patches (ungoogled + own); MV2 kept, web-store
  downloads proxied via self-hostable `helium-services`.
- Stock CEF already has no Google API keys, no sync, GCM disabled. Remaining pings are reduced via
  switches/policies at runtime.

## Prior art

- `Rajaniraiyn/CefSwift` (MIT, C API from Swift, SwiftPM bundler plugin, three hosting modes).
  Its "Arc-style" example fakes tabs with one shared browser that re-navigates (loses state).
- `briannadoubt/ChromiumKit` (Apache-2.0, alpha, Alloy only).
- Radian's author mentions "ChromeKit" (unreleased) — Swift-native Chromium like OpenAI's OWL and
  TBC's ADK (all proprietary, all built from Chromium source).

## Ad blocking (Brave)

- `brave/adblock-rust` (MPL-2.0, crate `adblock` 0.13.x): network matching, cosmetic resources,
  scriptlets, serialization; `content-blocking` feature emits Apple content-blocker JSON (WebKit).
- `brave/adblock-rust-ffi` archived; Brave now uses a `cxx` bridge. We wrap it with our own
  `extern "C"` staticlib.
- Default lists from `brave/adblock-resources/filter_lists/list_catalog.json` (EasyList, EasyPrivacy,
  uBO filters, Brave lists, cookie notices…).
- CEF hook: `CefResourceRequestHandler::OnBeforeResourceLoad` → `RV_CANCEL`; cosmetic CSS +
  scriptlets injected at `OnContextCreated` / on commit.
- Brave Rewards/BAT needs Brave's backend — not reusable. Creator-friendly alternative: per-site
  allow-listing and a site-declared policy.
