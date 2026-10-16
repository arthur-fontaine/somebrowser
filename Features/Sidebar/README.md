# Sidebar

**Purpose** — the Arc-style vertical sidebar that holds everything: traffic lights + navigation row,
address field, favorites grid, the space's pinned and Today tabs as a Horse-style tree, and a footer.
Hiding it (⌘S) gives an almost full-screen page; the left window edge reveals it as a floating panel.

**How it works**
- `SidebarLogic` — pure layout/tree math (instant hover hitbox, drop zones, drops, Markdown export,
  focus mode). Fully unit-tested.
- `SidebarView` / `TabList` / `TabRow` — SwiftUI. Rows are a flat precomputed list (`TabStore.rows`)
  in a `LazyVStack`; each row observes only its own `Tab`, so title/favicon changes re-render one row.
- Hover uses one `onContinuousHover` per list and the *target* layout (Radian's instant hitbox),
  so highlight is correct while rows spring.
- The selection is one Liquid Glass lens drawn behind all rows (`SelectionLens`) at the selected row's frame, which
  rows report as an anchor preference; it slides between rows. Rows themselves are washes, never glass (a lens per
  row smeared both titles while the glass re-formed).
- Everything is on one grid (`Design.Grid` in Core): shapes start 8 pt in, icons are centered on the red traffic
  light (x 26), titles start at x 42; a child's icon sits under its parent's title.
- Showing or hiding (`SidebarModel.toggle`) changes the window's state at once; the docked sidebar then slides in its
  own column while the page (a child window under Chromium) changes size once: before the slide when showing, after
  it when hiding (`isSidebarLeaving` keeps the column meanwhile). Switching spaces slides the same way.
- `SwipeCatcher` turns two-finger horizontal scrolls into an interactive space pager with a spring.

**Slots it hosts** — `sidebar.header`, `sidebar.address`, `sidebar.top`, `sidebar.footer`: other
features put controls there without importing this module.

**Commands & settings** — `feature.json` (⌘S toggle, ⌘⇧B focus mode, copy branch as Markdown). Drags and the row menus'
moves and closes go through Core's `SidebarHistory` (⌘Z undoes them).

**Tests** — `./forkctl test sidebar`.

**Remove it** — `./forkctl feature disable sidebar` and enable another feature that fills the
`sidebar` slot, e.g. a horizontal tab strip.
