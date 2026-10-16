# Address Bar

**Purpose** — The current site as a compact pill in the sidebar (Arc); click to edit.

**How it works** — Its end holds the `address-bar.trailing` slot (Navigation's reload, Extensions' actions), 28 pt
controls washed under the pointer. It publishes its frame (`window.addressFieldFrame`) so the command bar's inline
editor can grow from it, and fades out while `window.isEditingAddress` (the editor is drawn over it).

**Developer mode** (Arc) — `address-bar.developer-mode` (⌃D), per site: the pill shows host, port, path and query, with a
hammer. On for local servers (localhost, 127.0.0.1, `*.localhost`, `*.test`, `*.local`) unless turned off.

**Tests** — `./forkctl test address-bar`.

**Remove it** — `./forkctl feature disable address-bar`.
