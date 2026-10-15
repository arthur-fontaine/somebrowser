# Capture

**Purpose** — Arc's Capture: ⇧⌘2 freezes the page; drag over the part you want (Return: all of it, Esc: cancel). The
image goes to the clipboard, and the toast offers Save….

**How it works** — The engine's `snapshot` gives the visible page (Chromium: `Page.captureScreenshot`, from the renderer;
WebKit: `takeSnapshot`), shown frozen in the content overlay while you select; the selection is cropped from the
snapshot's pixels, so captures are at screen resolution.

**Commands** — `capture.start` — Capture… (⇧⌘2) · `capture.visible` — Capture Visible Page.

**Tests** — `./forkctl test capture`.

**Remove it** — `./forkctl feature disable capture`.
