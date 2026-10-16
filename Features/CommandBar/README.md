# Command Bar

**Purpose** — Arc's centered command bar. ⌘T opens it for a new tab, ⌘L edits the current address,
⌘⌥V pastes and goes. One list mixes: the address/search for what you typed, engine suggestions,
open tabs ("Switch to Tab"), results from any `OmniboxProvider` (history, Safari tabs…) and every
command as an action — so the whole browser is keyboard-drivable.

**How it works** — `CommandBarModel` (pure, tested) ranks items with `FuzzyMatch`; the SwiftUI panel
lives in the window `overlay` slot. ↑/↓ move, ↩ runs, Tab completes a site-search keyword, Esc closes.

**Look and motion** — Spotlight's: centered on the page a sixth of the way down, a radius half the field row's height
(a capsule with no results), a hairline above the results, a neutral selection wash. It fades in over 0.14 s while
settling from 96% (top edge held) and leaves in 0.12 s shrinking to 98%. Result icons are icons pages already showed
(`runtime.favicons`): typing contacts no site.

**Capabilities** — optional `SearchService` (falls back to plain URLs), any `OmniboxProvider`.

**Tests** — `./forkctl test command-bar`.
