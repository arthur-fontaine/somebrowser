# Split View

**Purpose** — Arc's Split View: two tabs side by side. ⌃⇧= splits the selected tab with the previous one, ⌃⇧] (or
a click on the pane's title) switches to the other pane, ⌃⇧- closes the split. Selecting any other tab ends it.

**How it works** — the selected tab keeps the window's content area; the other tab is shown in a pane in the
`content-trailing` slot, through its own engine viewport, and held awake (`holdAwake`, so hibernation and the archive
leave it alone). Switching panes selects the pane's tab: the engines move the two pages between viewports (a page
belongs to one viewport at a time). Opening and closing aren't animated: page frames never animate.

**Commands** — `split-view.open` (⌃⇧=), `split-view.swap` (⌃⇧]), `split-view.close` (⌃⇧-).

**Tests** — `./forkctl test split-view`; E2E on both engines (`splitViewShowsTwoPages`).

**Remove it** — `./forkctl feature disable split-view`.
