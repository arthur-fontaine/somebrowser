# Preview

**Purpose** — Radian Preview / Arc Peek: links from pinned tabs and favorites (or ⇧-click) open in a floating preview you can expand into a tab.

**How it looks** — a glass panel (`Radius.panel`, as the app's floating panels), a tile gutter inside the page card,
over a dimmed page (`Fill.scrim`). Its toolbar has no glass of its own: × and Open as Tab wash under the pointer, the
site (icon and host, as Arc's) sits centered. Drag the toolbar down to put it away.

**How it moves** — the page is an engine page (a child window under CEF), which can't follow an animated frame or
transform (AGENTS.md), so a stand-in moves and the page only ever sits still (`PeekModel.Phase`):
- opening: a card showing the site's icon and host grows from the click (`Motion.grow`), then the page shows in it;
- Open as Tab: the page is put away under its snapshot, the snapshot grows into the page card (`Motion.expand`), the
  tab takes the page, and the snapshot fades off it;
- closing: the same, the snapshot shrinks and fades (`Motion.leave`).
The page goes a frame before the card moves (its window lingered a frame, a ghost over the moving card). Each step moves
on by time, not on animation completions, which don't run with the window behind another app; a snapshot that takes
more than 150 ms isn't waited for.

**Commands**
- `peek.expand` — Open Preview as Tab (cmd+o)
- `peek.close` — Close Preview

**Settings**
- `peek.fromPinned` — Preview links opened from pinned tabs and favorites
- `peek.shiftClick` — ⇧-click a link to preview it

**Tests** — `./forkctl test peek`.

**Remove it** — `./forkctl feature disable peek`.
