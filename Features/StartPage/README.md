# Start Page

**Purpose** — Blank tabs show a column of sections, as Safari's start page does: a search field, your favorites, then
what other features contribute to the `start-page.extras` slot (History's frequently visited sites, Archive's recently
archived tabs, AdBlock's privacy line, Safari's favorites).

**How it works** — The column is left-aligned, 680 pt wide, near the top of the page. Sections use Core's
`PageSection`, `SiteTile` and `PageRow`, so contributions read alike. Everything shown is local: tiles show icons
pages already showed (`runtime.favicons`), so a blank tab contacts no site.

**Tests** — `./forkctl test start-page`.

**Remove it** — `./forkctl feature disable start-page`.
