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
(`EngineHooks.addDocumentStartScript`). Both come from a resources file in adblock-rust's format, downloaded with the
lists and loaded into the engines: today Brave's own (`brave/adblock-resources`); uBlock Origin's stand-ins and
scriptlets, which Brave bundles through its component updater, are still to add.

**Commands** — `adblock.toggle-site`, `adblock.update-lists`. **Settings** — `adblock.enabled`,
`adblock.supportCreators`, `adblock.cosmetic`.

**Tests** — `./forkctl test adblock`.

**Remove it** — `./forkctl feature disable adblock`.
