# Preview

**Purpose** — Radian Preview / Arc Peek: links from pinned tabs and favorites (or ⇧-click) open in a floating preview you can expand into a tab.

**How it looks** — Safari's iOS bar, on a Mac: the page sits in a Liquid Glass container (`Radius.panel`, an 8 pt rim,
the page concentric inside), a tile gutter inside the page card, over a dimmed page (`Fill.scrim`). A row of glass controls floats 12 pt above it:
the site's capsule centered, then Open as Tab (`arrow.up.forward.square`; expanding arrows read as Full Screen) and ×
as circles. The capsule is Core's `AddressCapsule`, as the sidebar's address field looks, but it isn't one: the site
alone (icon and host, as Arc's), reload at its end, a click opens the tab. The row fades in once the page shows and
lifts away as the page grows into the tab; drag it down to put the preview away.

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
