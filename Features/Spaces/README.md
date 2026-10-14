# Spaces

**Purpose** — Arc Spaces: separate sets of pinned/Today tabs, each with a name, icon and gradient
theme that tints the window. Switch with ⌃1–9, ⌘⌥←/→, the footer switcher or a two-finger swipe
(the swipe itself lives in the sidebar).

**Contributes** — `background` (theme gradient), `sidebar.footer` (switcher), `overlay` (editor).

**Tests** — `./forkctl test spaces`.

**Remove it** — `./forkctl feature disable spaces` (the model keeps a single space).
