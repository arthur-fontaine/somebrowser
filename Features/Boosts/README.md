# Boosts

**Purpose** — Arc's Boosts: make a site yours. Per site, your CSS, your JavaScript, and zapped elements (click things
to hide them on every visit). ⌃⌘B opens the editor, ⌘⌥Z zaps; site controls show the site's Boost with a switch.

**How it works** — a Boost is stored with the site's settings (`boosts.boost`, JSON; sites are hosts without `www.`)
and given to the engine as a document-start script (`EngineHooks.addDocumentStartScript`): the CSS (zapped elements
included) goes in a constructed stylesheet before the first paint, so there's no flash and page CSP doesn't block it;
the JavaScript runs once the document is parsed, in the page. Scripts are syntax-checked with JavaScriptCore on save:
a script that doesn't parse would break the other features sharing the injection (ad blocking scriptlets), so it
never reaches the page. Zap mode outlines the element under the pointer; a click hides it and reports a selector,
which is accepted only from a tab in zap mode.

**Commands** — `boosts.edit` (⌃⌘B), `boosts.zap` (⌘⌥Z), `boosts.toggle-site`.

**Tests** — `./forkctl test boosts`; E2E on both engines (`boostsApplyBeforeThePage`).

**Remove it** — `./forkctl feature disable boosts` (Boosts stay in site settings).
