# Start Page

**Purpose** — Blank tabs show a column of sections, as Safari's start page does: a search field (only with the command
bar's palette style: inline, addresses are typed in the sidebar's field, as in Safari), your favorites, then
what other features contribute to the `start-page.extras` slot (History's frequently visited sites, Archive's recently
archived tabs, AdBlock's privacy line, Safari's favorites).

**How it works** — The column is left-aligned, 680 pt wide, near the top of the page. Sections use Core's
`PageSection`, `SiteTile` and `PageRow`, so contributions read alike. Everything shown is local: tiles show icons
pages already showed (`runtime.favicons`), so a blank tab contacts no site. Before there's any history, a Get Started
section offers importing from another browser and making this one the default (`start-page.make-default`).

**Arranging** — Favorites and each `start-page.extras` contribution are movable sections: drag one by its header
(it moves as the pointer reaches another) or use the header's menu (Move Up, Move Down, which skip empty sections).
Core's `PageSection` reads the move from the environment (`pageSectionMover`), so contributions need nothing for it.
The order is kept in `layout.json` in the feature's data folder (`StartPageLayout`); a section never arranged lands
after the one before it by default. Sections with nothing to show take no room (`SectionColumn`).

**Tests** — `./forkctl test start-page`.

**Remove it** — `./forkctl feature disable start-page`.
