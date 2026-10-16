# Appearance

**Purpose** — The browser's own surfaces in Liquid Glass, following Apple's guidance (WWDC25 "Meet Liquid Glass",
the Landmarks sample): glass is the navigation layer floating over content, never content itself. Controls are
interactive glass (`glassControl(in:)`, Core): the navigation buttons as one piece of glass, the sidebar toggle, the
address field, extension and download buttons, the spaces' segmented control, favorites as tiles, and the selected tab
as a lens that flows from row to row (one `GlassGroup` and a shared `glassEffectID`). Panels, bars and toasts are glass
surfaces (`glassSurface(in:)`). Related glass shares a `GlassGroup` (glass can't sample glass); tint only where color
means something (the open favorite). Pages, and lists inside a panel, are content and stay opaque.

Behind it all, around the page, the desktop shows through the window (`appearance.backdrop`: `desktop`, the system's
full-screen UI material, which lets the desktop's light and shapes through for the glass to refract; or `frosted`,
the nearly opaque sidebar material). `appearance.glass`: `glass` (regular, default), `clear` (more see-through), or
`solid` for those who find glass hard to read. The system's own Liquid Glass setting and Reduce Transparency apply.

**Contributes** — `background` (the window surface).

**Tests** — `./forkctl test appearance`.
