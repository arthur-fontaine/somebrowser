# Appearance

**Purpose** — The browser's own surfaces in Liquid Glass: the window around the page, and through
`glassSurface(in:)` (Core) every panel, bar and toast. Pages are content and stay opaque; lists inside a panel are
content too (no glass on glass). Setting `appearance.glass`: `glass` (default) or `solid`, for those who find glass
hard to read. The system's own Liquid Glass setting (macOS 26.1's Clear/Tinted, 27's slider) and Reduce Transparency
apply to the glass; the app has no intensity of its own, which would fight the system's.

**Contributes** — `background` (the window surface).

**Tests** — `./forkctl test appearance`.
