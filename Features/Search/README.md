# Search

**Purpose** — decides whether typed text is an address or a search, builds the URL for the chosen
engine (DuckDuckGo by default — no Google unless you pick it), supports keyword site search
(`yt cats`, configurable) and fetches suggestions only when the user allows it.

**Capabilities** — provides `SearchService` (Core contract). The command bar and start page use it.

**Tests** — `./forkctl test search`: URL detection, URL building, keywords, engine switching,
suggestion parsing and the privacy toggle.

**Remove/replace** — disable it and provide another `SearchService` (e.g. a fork with a private
search backend).
