# Command Bar

**Purpose** — Arc's centered command bar. ⌘T opens it for a new tab, ⌘L edits the current address (a results page's search terms),
⌘⌥V pastes and goes. One list mixes: the address/search for what you typed (an address with its search right
under it, as "node.js" may be a query), engine suggestions (always searches), open tabs ("Switch to Tab"), results
from any `OmniboxProvider` (history, Safari tabs…) and every command as an action — so the whole browser is
keyboard-drivable. With nothing typed it lists recent pages; past searches among them (any known engine's results
page) show as their terms, which the arrows fill in to edit, and run with the current engine.

**How it works** — `CommandBarModel` (pure, tested) ranks items with `FuzzyMatch`; the SwiftUI panel
lives in the window `overlay` slot. ↑/↓ move, ↩ runs, Tab completes a site-search keyword, Esc closes.

**Top hit** — when what's typed surely names a site, that site comes first, before the search, so ↩ opens it (Safari's
Top Hit): "x" → x.com, "gmail" → mail.google.com. Core's `TopHit` matches the start of a site's domain, of one of its
names (google in mail.google.com) or of a word of its pages' titles (Gmail), and weighs visits with a two-week
half-life. History providers offer their best site (`OmniboxItem.isTopHit`); a short list of brands whose site has
another name (gmail, gcal, twitter, yt…) works without history. One letter needs more visits; an address typed stays
first. Results wash under the pointer; only the arrows select (they fill the field).

**Two styles** (`command-bar.style`):
- `inline` (default): the sidebar's address field grows into one glass panel, its top-left held and 480 pt wide over
  the page, as Spotlight's bar grows into its results; the results sit on the sidebar's grid. It's drawn in the
  overlay at the frame the field publishes. ⌘T opens the new tab first and types its address there (Safari's way;
  a blank tab left untouched because you switched to another is closed). With the sidebar hidden, ⌘L floats it in.
  Esc reverts what was typed, then closes; a click anywhere else closes; ⌥↩ opens in a new tab.
- `palette`: Arc's, centered on the page a sixth of the way down. Its radius is half the field row's height (a capsule
  with no results), a hairline above the results, a neutral selection wash; it fades in over 0.14 s while settling
  from 96% and leaves in 0.12 s shrinking to 98%.

Result icons are icons pages already showed (`runtime.favicons`): typing contacts no site.

**Capabilities** — optional `SearchService` (falls back to plain URLs), any `OmniboxProvider`.

**Tests** — `./forkctl test command-bar`.
