# Spaces

**Purpose** — Your tabs live in one space. Two more come and go: a private space (⌘⇧N, New Private Tab) whose tabs
keep nothing, and a Claude space with the tabs Claude controls. With two or more, the sidebar's footer shows one
symbol per space; ⌘⌥←/→ and a two-finger swipe switch too (the swipe lives in the sidebar).

**Private space** — Leaving it locks it for that window; coming back asks for Touch ID (or the Mac's password)
before its tabs and pages show (`spaces.unlock`). While locked, the sidebar lists none of its tabs and the content
area shows the lock. It ends with its last tab, and is never saved. The runtime holds the model
(`BrowserRuntime.openPrivateTab`, `unlockPrivateSpace`, `SpaceKind`).

**Contributes** — `sidebar.footer` (switcher), `contentOverlay` (lock screen).

**Tests** — `./forkctl test spaces` (Touch ID through a replaceable `SpacesFeature.authenticate`).
