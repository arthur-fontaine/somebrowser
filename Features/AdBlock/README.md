# Ad Blocking

**Purpose** — Brave's ad blocker: its engine (`adblock-rust`, MPL-2.0) with Brave's default lists (EasyList,
EasyPrivacy, uBlock Origin filters/privacy/unbreak, Brave unbreak). Network blocking, cosmetic hiding (page-specific
and generic), URL cleaning (`removeparam`), a per-site switch with a blocked counter in site controls.

**Creators** — Brave lets creators earn through Brave Rewards, which needs Brave's servers. Instead, sites can ask:
a page declaring Web Monetization (`<link rel="monetization">`) keeps its ads when "support creators" is on.
Lists are split like Brave's: privacy lists (trackers) always apply; ad lists are relaxed on those sites.

**How it works** — `Native/` is a small Rust crate exposing a C API over adblock-rust; `forkctl` builds it
(`"cargo": "Native"` in `feature.json`). Chromium: request filter on the network thread. WebKit: lists converted to
an Apple content-blocker rule list. Compiled engines are cached; lists refresh weekly and are first fetched when you
start browsing (an idle browser contacts nobody).

**Resources** — `redirect=` filters answer with a harmless stand-in instead of failing the request
(`RequestVerdict.respond`), and `##+js(…)` scriptlets run at document start, before the page's own scripts
(`EngineHooks.addDocumentStartScript`): e.g. uBlock Origin's YouTube rules empty `ytInitialPlayerResponse.adPlacements`
before the player reads it. The resources are the set Brave ships: uBlock Origin's stand-ins and scriptlets, assembled
from uBO's latest GitHub release (`UboResources` bundles its ES modules for JavaScriptCore, as Brave's packager does
with Node; re-assembled only when uBO releases), plus Brave's own (`brave/adblock-resources`). uBO's own lists are
trusted (they may use `trusted-*` scriptlets), as in uBO. Brave distributes this set through its component updater,
which requires Brave's credentials.

**Commands** — `adblock.toggle-site`, `adblock.update-lists`. **Settings** — `adblock.enabled`,
`adblock.supportCreators`, `adblock.cosmetic`.

**Tests** — `./forkctl test adblock` (a miniature uBO build covers the module forms; set `UBO_EXTENSION_DIR` to an
unpacked uBO release to check a new release still assembles).

**Remove it** — `./forkctl feature disable adblock`.
