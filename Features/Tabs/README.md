# Tabs

**Purpose** — every tab command: new/close/reopen, switching (⌘1…9, ⌘⌥↑/↓), Horse-style tree
navigation (⌘⇧←/→/↑/↓), moving and nesting (⌘⌥⇧ arrows), pin (⌘D), favorite, duplicate, rename,
mute, clear Today (⌘⇧K, undoable) and the per-tab "open links in this tab" toggle (⌘Y). Moves, pins and closes are
recorded in Core's `SidebarHistory`, so ⌘Z / ⇧⌘Z undo and redo them (Arc) when no text field has the keyboard.

**How it works** — `TabsFeature` binds the commands declared in `feature.json` to `BrowserRuntime`
(selection, closing, live pages) and `TabStore` (tree). It has no UI of its own.

**Capabilities** — provides `tabs.commands`; requires nothing.

**Settings** — `tabs.closeKeepsChildren` (Horse ⌘W promotes children), `tabs.dedupLinks`.

**Tests** — `./forkctl test tabs`: every command has a handler, tree close/reopen, number shortcuts
follow sidebar order, tree navigation, indent/outdent, pin, clear Today, open-in-place, duplicate.

**Remove it** — `./forkctl feature disable tabs` (you lose the commands; the model still works).
