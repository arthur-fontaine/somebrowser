# Import

**Purpose** — "Switch with all your data" (Radian): bookmarks, history and extensions from Chrome, Arc, Dia,
ChatGPT Atlas, Helium, Brave, Edge, Vivaldi and Chromium, and Safari (offered by the Safari feature).

**How it works** — Chromium browsers keep profiles under `~/Library/Application Support` (not privacy-protected):
`Local State` names the profiles, `Bookmarks` is JSON, `History` is SQLite (read from a copy: the browser may be
running), extensions come from `Secure Preferences` (Core's `ChromiumExtensions`). Bookmarks become a collapsed pinned
folder in the current space, as Arc does; history goes through `HistoryService.importEntries`; Web Store extensions
are listed with an "Add" button (installing needs the user's click on the store).

Other features offer more sources through the `BrowserImportSource` capability (listed first, read through the
source): the Safari feature offers Safari's bookmarks and history.

**Not yet** — Arc's own sidebar (spaces and pinned tabs in `StorableSidebar.json`).

**Commands** — `import.open` (File › Import from Another Browser…).

**Tests** — `./forkctl test import` (a fixture Chromium profile; a contributed source).

**Remove it** — `./forkctl feature disable import`.
