# Link Tree

**Purpose** — browser.horse's core idea: a link click never replaces the page; it opens as a child of
the page that opened it, so the sidebar becomes a tree of where you went. App-like sites (mail, chat,
social, docs…) are excluded by default and keep normal in-place navigation; ⌘⌥Y switches a single
tab to "open links in place", and Claude's tabs (the Claude space) always do, so Claude follows its own clicks; a
page that is already open is focused instead of duplicated. A small
box at the bottom of the page shows where a hovered link goes and whether it's already open.

**How it works** — a navigation policy (`EngineHooks.addNavigationPolicy`) returns
`.openInNewTab` for user link clicks; the engine creates the page and the runtime parents it under
the source tab. Popups and ⌘-clicks were already children (Core).

**Settings** — `tree-links.enabled`, `tree-links.sameSite`, `tree-links.focusExisting`,
`tree-links.exclusions`, `tree-links.hoverBox`.

**Tests** — `./forkctl test tree-links`.
