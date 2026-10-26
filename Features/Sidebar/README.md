# Sidebar

**Purpose** — the Arc-style vertical sidebar that holds everything: traffic lights + navigation row,
address field, favorites grid, the space's pinned and Today tabs as a Horse-style tree, and a footer.
Hiding it (⌘S) gives an almost full-screen page; the left window edge reveals it as a floating panel.

**How it works**
- `SidebarLogic` — pure layout/tree math (instant hover hitbox, drop placements, drops, Markdown export,
  focus mode). Fully unit-tested.
- `SidebarView` / `TabList` / `TabRow` — SwiftUI. Rows are a flat precomputed list (`TabStore.rows`)
  in a `LazyVStack`; each row observes only its own `Tab`, so title/favicon changes re-render one row.
- Hover comes from one AppKit tracking area per list (`PointerTracker`: SwiftUI's hover reports trailed the pointer)
  and the *target* layout (Radian's instant hitbox), so highlight is correct while rows spring.
- The selection is one Liquid Glass lens drawn behind all rows (`SelectionLens`) at the selected row's frame, which
  rows report as an anchor preference; it slides between rows. Rows themselves are washes, never glass (a lens per
  row smeared both titles while the glass re-formed).
- ⇧-click picks the tabs from the one shown to the clicked one (Finder); picked rows are washed, the lens stays on the
  tab shown. Their row menu then acts on all of them (pin, favorites, copy links, move to a space, close), each action
  undone by one ⌘Z (`SidebarHistory.group`). A plain click or switching spaces drops the picks.
- Everything is on one grid (`Design.Grid` in Core): shapes start 8 pt in, icons are centered on the red traffic
  light (x 26), titles start at x 42; a child's icon sits under its parent's title.
- Showing or hiding (`SidebarModel.toggle`) changes the window's state at once; the docked sidebar then slides in its
  own column while the page (a child window under Chromium) changes size once: before the slide when showing, 50 ms
  before its end when hiding (`isSidebarLeaving` keeps the column meanwhile). The slide runs in Core Animation on the
  sidebar's own hosting view (`SidebarSlideHost`), so it keeps moving while Chromium's resize holds the main thread.
  The traffic lights wait for it to land (`isSidebarArriving`). Switching spaces slides too.
- Spacing follows `Design.Space` (2 between rows, 8 between blocks, 12 around the divider); the footer
  (`FooterLayout`) keeps the space switcher on the sidebar's axis between its leading and trailing buttons.
- Dragging: each list is one drop target. A row's middle half nests into it; elsewhere the nearest gap, at the depth
  the pointer is over (Finder's outlines), so the line starts at that depth's icon and, under the end of a branch,
  moving left lands after an ancestor. One mark per list glides between gaps and grows into an outline to nest. Dropping on
  the divider ends pinned; with nothing pinned yet, the New Tab row's top half pins. Below it, Today begins. Nothing opens as a drag starts:
  the empty favorites grid opens only once the drag reaches the address field. `SidebarModel.endDrag` clears the drag on
  every drop, and on a drag that ends elsewhere (Esc, released outside) once the mouse button is up.
- `SwipeCatcher` turns two-finger horizontal scrolls into an interactive space pager with a spring.

**Slots it hosts** — `sidebar.header`, `sidebar.address`, `sidebar.top`, `sidebar.footer`: other
features put controls there without importing this module.

**Commands & settings** — `feature.json` (⌘S toggle, ⌘⇧B focus mode, copy branch as Markdown). Drags and the row menus'
moves and closes go through Core's `SidebarHistory` (⌘Z undoes them).

**Tests** — `./forkctl test sidebar`.

**Remove it** — `./forkctl feature disable sidebar` and enable another feature that fills the
`sidebar` slot, e.g. a horizontal tab strip.
