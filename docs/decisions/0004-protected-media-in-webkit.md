# 0004 — Protected media (Netflix…) plays in WebKit tabs

Date: 2026-10-15 · Status: accepted

## Context

Netflix and other DRM services must work. On a Mac, Chromium plays them with Widevine, but a custom Chromium build
needs Widevine's VMP certification: about $7,000 upfront plus a yearly fee, through castLabs, after an audit. Free
signing (castLabs EVS) covers only their unmodified Electron. ungoogled-chromium closed the request as "not possible"
for open-source builds. Apple's FairPlay, which Safari uses for the same services, works in any app's `WKWebView`.
Checked 2026-10-15 in this app, unsigned:
- `requestMediaKeySystemAccess('com.apple.fps')` is granted, while Widevine isn't;
- EZDRM's public FairPlay demo stream (Bitmovin's demo asset) is licensed and decodes at 1280×720 with no dropped
  frames.

The user preferred keeping such pages in Chromium and handing only the protected video to WebKit. That would mean
bridging the page's MediaSource/EME objects to a hidden WebKit video drawn under a transparent Chromium page, and
making the Chromium page pass for Safari, since Netflix picks FairPlay by browser. That is not attempted until the
whole-tab path below is proven with the services.

FairPlay paths checked in the browser's WebKit tabs on 2026-10-16:

| Path | Result |
|---|---|
| Safari's legacy key API (`WebKitMediaKeys`, `com.apple.fps.1_0`) with native HLS | Plays (EZDRM's live license) |
| Modern EME with MediaSource (fMP4 cbcs), how Netflix-like players stream | Plays: EZDRM's public demo (Shaka's "Big Buck Bunny (FairPlay)") licensed, 1280×720 at 24 fps, no dropped frames. Opt-in E2E `fairPlayPlaysThroughMediaSource` (`BROWSER_E2E_NETWORK=1`). Axinom's vectors can't be used: its license server refuses its own published tokens, none of which carries the IV it requires |
| Modern EME with native HLS | "decode error": an Apple bug Axinom's own player works around by using the legacy API |

WebKit's feature flags in these tabs are WKWebView's defaults (EME, legacy EME, MediaSource and Managed MediaSource on),
and Safari sets no media preferences of its own.

## Decision

- The CEF engine hosts a WebKit engine sharing its hooks (scripts, content rule lists, policies), made on first use.
- In Chromium pages a document-start script wraps `navigator.requestMediaKeySystemAccess`. A request for Widevine,
  PlayReady or FairPlay posts `__protectedMedia` and never settles. The engine then remembers the page's site
  (`protected-media-sites.json` in the engine profile) and asks the runtime to recreate the tab
  (`EngineHooks.onRecreateTab`). The new page is a WebKit tab with a Safari user agent, the installed Safari's version.
- Pages of remembered sites open in WebKit directly, from a link, a typed URL or a restored session. A link the user
  follows from a WebKit page to another site goes back to Chromium. Clear Key stays in Chromium.
- `CEFViewport` shows WebKit tabs through the WebKit engine's viewport in the same container. Picture in picture
  delegates to the WebKit engine.
- Engine option `protectedMedia`: `webkit` (default), `chromium` (a Widevine build: Chrome's updater fetches only the
  Widevine CDM, through our patch's `--widevine-only-components`), `off`.

## Consequences

- Netflix, Disney+, Prime Video and the like run on WebKit, with FairPlay quality, Apple's hardware decode and no
  Google component download.
- Those tabs don't run Chrome extensions. Ad blocking uses the WebKit content rule lists the AdBlock feature already
  produces. Their cookies live in WebKit's data store: you sign in once there.
- A fork with VMP certification sets `protectedMedia: chromium`.
