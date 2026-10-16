# Navigation

**Purpose** — back/forward/reload/stop, zoom (remembered per site), developer tools, view source,
and Arc's "Super Copy" (⌘⇧C copies the URL without tracking parameters; ⌘⌥⇧C as Markdown).
Contributes the back/forward/reload buttons to `sidebar.header`.

**Tests** — `./forkctl test navigation`: history buttons, disabled states, zoom steps and memory,
tracker stripping.
