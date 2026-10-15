# Website Shortcuts

**Purpose** — Arc's "prefer website shortcuts": with the setting on, a page that uses a browser shortcut gets it (⌘F
in a document, ⌘D or ⌘= in a design tool, ⌘[ to outdent…). Pressing it twice quickly runs the browser's command, as
does pressing it on a page that doesn't use it. Tab and window shortcuts (⌘T, ⌘L, ⌘W, ⌘N, ⌘⇧T, ⌘1–9, ⌃Tab, ⌃1–9)
always stay the browser's.

**How it works** — the feature answers `EngineHooks.pageFirstShortcut` for the commands bound to a key (user remaps
included). Chromium: the bridge lets such a key go to the page first (`OnPreKeyEvent` marks it a shortcut) and runs the
browser's menu item in `OnKeyEvent` if the page didn't consume it; a second press within half a second skips the
page. Engines without the hook keep the browser first.

**Settings** — `website-shortcuts.prefer` (off by default, as in Arc).

**Tests** — `./forkctl test website-shortcuts` (which keys go to pages). The routing itself needs the app frontmost
(key events only reach a key window), so it is checked by hand with the automation socket's `key` op: launch with
`open -n --env …` (LaunchServices brings it to the front), then `{"op":"key","key":"d","modifiers":["cmd"],"keyCode":2,"page":true}`.

**Remove it** — `./forkctl feature disable website-shortcuts`.
