# Search

**Purpose** — decides whether typed text is an address or a search, builds the URL for the chosen
engine (DuckDuckGo by default — no Google unless you pick it), supports keyword site search
(`yt cats`, configurable) and fetches suggestions only when the user allows it. On the engine's results page it
gives back what was searched, so ⌘L edits those terms rather than the URL (Chrome's).

**Capabilities** — provides `SearchService` (Core contract). The command bar and start page use it.

**Tests** — `./forkctl test search`: URL detection, URL building, keywords, engine switching,
a results page's terms, suggestion parsing and the privacy toggle.

**Remove/replace** — disable it and provide another `SearchService` (e.g. a fork with a private
search backend).
