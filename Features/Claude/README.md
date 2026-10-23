# Claude

**Purpose** — The tabs Claude controls gather in a Claude space (its symbol shows in the sidebar's space switcher
once it exists), apart from your own. It holds only those: a tab you open while it shows goes to your space, and its tabs' addresses can't be edited. Claude drives the browser through the Claude in Chrome extension, from Claude
Code (`claude --chrome`) or the Claude apps; the CEF engine mirrors Chrome's native messaging manifests into its
profile so they reach it (`NativeMessagingHosts`).

**How it works** — a session's tabs go there as they open: the extension opens them in the background on Chrome's
new-tab page (`tabs.create({url: "chrome://newtab/", active: false})`), which no web page can open (another extension
doing the same would land there too). On the user's own tabs, the extension marks the pages it acts on (its glow
`#claude-agent-glow-border`, its Stop button `#claude-agent-stop-container`, and on its other tabs
`#claude-static-indicator-container`). Since 1.0.102 they sit in a closed shadow root, so only its host shows: a `div`
with no attributes or children at the end of `<body>`, computed `display: contents`. A main-frame script watches for
those elements or that host and tells the feature, which moves the tab (with its children) to the top of the Claude
space; a window showing it follows. While Claude works on a tab of its space, the tab's row glows and beats as the
extension's page does, and the space's spark plays Claude's thinking animation (stopping on the logo): the extension
keeps its own working marks out of the page's reach (no Stop button for Claude Code), so the feature counts what it
can see, navigations and trusted input on a marked page (Claude clicks, types and scrolls through the debugger), and
keeps the animation 5 s past the last one, across reads and screenshots. Private tabs never move. Move to Your Tabs
(row menu) brings one back. Setting `claude.space`.

**Limits** — the extension makes its tabs with `tabs.create` and groups them (`tabs.group`); here Chrome's own new
tabs are reopened as the browser's, so their ids don't last, and each page is a window of its own (no group of
several). Claude acting on a tab you opened works; tabs it opens itself need the CEF patch described in
docs/decisions/0005. A page in the background shows no mark until it's seen (the extension waits for that).

**Tests** — `./forkctl test claude`.
