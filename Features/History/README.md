# History

**Purpose** — local browsing history in SQLite (system libsqlite3): ⌘Y panel grouped by day with
search, command-bar results ranked by frecency, clear today/all, retention in days. Private windows
and the "remember history" switch are respected.

**Capabilities** — provides `HistoryService` and an `OmniboxProvider`. With `SearchService` (optional), a past search
(any known engine's results page) is listed as its terms: the command bar's arrows fill them in to be edited, and it
runs again with the current engine.

**Sidebar** — a History button in the sidebar's footer opens the panel.

**Start page** — contributes "Frequently Visited": the sites visited most (by visits to all their pages), favorites
aside.

**Tests** — `./forkctl test history`.
