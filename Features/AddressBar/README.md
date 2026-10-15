# Address Bar

**Purpose** — The current site as a compact pill in the sidebar (Arc) or the toolbar (Radian); click to edit.

**Developer mode** (Arc) — `address-bar.developer-mode` (⌃D), per site: the pill shows host, port, path and query, with a
hammer. On for local servers (localhost, 127.0.0.1, `*.localhost`, `*.test`, `*.local`) unless turned off.

**Tests** — `./forkctl test address-bar`.

**Remove it** — `./forkctl feature disable address-bar`.
