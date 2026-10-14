# Command Bar

**Purpose** — Arc's centered command bar. ⌘T opens it for a new tab, ⌘L edits the current address,
⌘⌥V pastes and goes. One list mixes: the address/search for what you typed, engine suggestions,
open tabs ("Switch to Tab"), results from any `OmniboxProvider` (history, Safari tabs…) and every
command as an action — so the whole browser is keyboard-drivable.

**How it works** — `CommandBarModel` (pure, tested) ranks items with `FuzzyMatch`; the SwiftUI panel
lives in the window `overlay` slot. ↑/↓ move, ↩ runs, Tab completes a site-search keyword, Esc closes.

**Capabilities** — optional `SearchService` (falls back to plain URLs), any `OmniboxProvider`.

**Tests** — `./forkctl test command-bar`.
