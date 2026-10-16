# Claude

**Purpose** — The tabs Claude controls gather in a Claude space (its symbol shows in the sidebar's space switcher
once it exists), apart from your own. Claude drives the browser through the Claude in Chrome extension, from Claude
Code (`claude --chrome`) or the Claude apps; the CEF engine mirrors Chrome's native messaging manifests into its
profile so they reach it (`NativeMessagingHosts`).

**How it works** — the extension marks the pages it acts on (its glow `#claude-agent-glow-border`, its Stop button
`#claude-agent-stop-container`, and on its other tabs `#claude-static-indicator-container`). A main-frame script
watches for those elements and tells the feature, which moves the tab (with its children) to the top of the Claude
space; a window showing it follows. Private tabs never move. Move to Your Tabs (row menu) brings one back. Setting
`claude.space`.

**Limits** — the extension makes its tabs with `tabs.create` and groups them (`tabs.group`); here Chrome's own new
tabs are reopened as the browser's, so their ids don't last, and each page is a window of its own (no group of
several). Claude acting on a tab you opened works; tabs it opens itself need the CEF patch described in
docs/decisions/0005. A page in the background shows no mark until it's seen (the extension waits for that).

**Tests** — `./forkctl test claude`.
