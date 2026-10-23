# Import

**Purpose** — "Switch with all your data" (Radian): bookmarks, history, extensions and cookies from Chrome, Arc, Dia,
ChatGPT Atlas, Helium, Brave, Edge, Vivaldi and Chromium, and Safari (offered by the Safari feature).

**How it works** — Chromium browsers keep profiles under `~/Library/Application Support` (not privacy-protected):
`Local State` names the profiles, `Bookmarks` is JSON, `History` is SQLite (read from a copy: the browser may be
running), extensions come from `Secure Preferences` (Core's `ChromiumExtensions`). Bookmarks become a collapsed pinned
folder in the current space, as Arc does; history goes through `HistoryService.importEntries`; Web Store extensions
are listed with an "Add" button (installing needs the user's click on the store).

**Cookies** — so sites stay signed in. `Cookies` (or `Network/Cookies`) is SQLite; values are `v10` + AES-128-CBC
(IV of 16 spaces) under a key derived with PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds) from the browser's
"<name> Safe Storage" password in the login Keychain (Chrome's is "Chrome Safe Storage"; only Chrome's was checked
here, the others follow the pattern). From database version 24 the plaintext starts with SHA-256 of the host, checked
and dropped. Rows are read for the preview; the Keychain is read only on import, off the main thread, and macOS asks
the user first. Partitioned (CHIPS) and expired cookies are skipped. They go to the engine through Core's
`EngineCookieStore` (the Cookies toggle shows only when the engine is one), replacing cookies with the same name,
domain and path. Sign-ins kept in localStorage/IndexedDB, or bound to the device, still ask again.

Other features offer more sources through the `BrowserImportSource` capability (listed first, read through the
source): the Safari feature offers Safari's bookmarks and history.

**Arc's Spaces** — Arc keeps each Space's pinned tabs and folders outside the profile, in `StorableSidebar.json` beside
`User Data`; an Arc profile's import adds them as an "Arc Spaces" folder (one folder per Space of that profile). The
format follows arc-export's reading of it; there was no Arc sidebar on this Mac to check against.

**Commands** — `import.open` (File › Import from Another Browser…).

**Protected folders** — macOS 27 keeps Chrome's folder from other apps: reading it fails with "Operation not
permitted", without a prompt. Such a browser is listed as "Needs your permission"; "Allow Access…" opens an open panel
on its folder, and picking it is consent macOS honors (`FolderGrants`, security-scoped bookmarks in `Grants/`, kept
across launches). Sources other features offer (Safari) are read only once clicked, since they may ask for access.

**Tests** — `./forkctl test import` (a fixture Chromium profile with an encrypted `Cookies` database; an Arc sidebar; a
contributed source).

**Remove it** — `./forkctl feature disable import`.
