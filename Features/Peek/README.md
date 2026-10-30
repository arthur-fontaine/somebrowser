# Preview

**Purpose** — Radian Preview / Arc Peek: links from pinned tabs and favorites (or ⇧-clicked, as set) open in a floating preview you can expand into a tab.

**When** — a navigation policy, by `peek.trigger`: "click" previews a click from a pinned tab or favorite to another site
and opens a ⇧-click as a tab; "shift" previews a ⇧-click on any link and leaves clicks alone. Chromium doesn't navigate on
a ⇧-click but opens a new window: the policy sees it too (`NavigationAction.disposition`) and takes it instead. ⌘-clicks
open the tab they ask for.

**How it looks** — Safari's iOS bar, on a Mac: the page sits in a Liquid Glass container (`Radius.panel`, an 8 pt rim,
the page concentric inside), a tile gutter inside the page card, over a dimmed page (`Fill.scrim`). A row of glass
controls floats 12 pt above it, at the header's foot (level with the sidebar's address field, clear of the traffic
lights): the site's title centered (its icon and host, a label hugging them, not a field), then Open as Tab
(`arrow.up.forward.square`; expanding arrows read as Full Screen) and × as circles. The row fades in once the page shows
and lifts away as the page grows into the tab; drag it down to put the preview away.

**How it moves** — the page is an engine page (a child window under CEF), which can't follow an animated frame or
transform (AGENTS.md), so a stand-in moves and the page only ever sits still (`PeekModel.Phase`):
- opening: a white card showing the site's icon and host grows from the click (`Motion.grow`), then the page shows in it;
- Open as Tab: the page is put away under its snapshot, the snapshot grows into the page card (`Motion.expand`) as the
  glass closes its rim and takes the card's corners, the tab takes the page, and the snapshot and glass fade off it;
- closing: the same, the snapshot shrinks and fades (`Motion.leave`).
The page goes a frame before the card moves (its window lingered a frame, a ghost over the moving card). Each step moves
on by time, not on animation completions, which don't run with the window behind another app; a snapshot that takes
more than 150 ms isn't waited for.

**Commands**
- `peek.expand` — Open Preview as Tab (cmd+o)
- `peek.close` — Close Preview

**Settings**
- `peek.trigger` — Preview links with: `click` (from pinned tabs and favorites; ⇧-click opens a tab) or `shift` (⇧-click
  any link; a click opens it as usual)

**Tests** — `./forkctl test peek`.

**Remove it** — `./forkctl feature disable peek`.
