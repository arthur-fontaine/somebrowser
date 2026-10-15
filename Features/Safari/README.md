# Safari Sync

**Purpose** — Radian's Safari ⇄ iPhone sync: the start page shows Safari's Favorites and follows Safari's file (so
iPhone changes arrive on Safari's sync schedule); a favorite added here appears in Safari and on the iPhone; "iCloud
Tabs" lists the iPhone's open tabs; Safari's history (iPhone included) appears in the command bar.

**How it works** — Safari's sync agents (`SafariBookmarksSyncAgent`, `com.apple.Safari.History`) keep what iCloud
syncs in local files, decrypted (History and iCloud Tabs are end-to-end encrypted, so only they can):

| File | Folder | Used for |
|---|---|---|
| `Bookmarks.plist` | `~/Library/Safari` | Favorites (the `BookmarksBar` list), read and written |
| `History.db` | `~/Library/Safari` | Command bar suggestions |
| `CloudTabs.db` | `~/Library/Containers/com.apple.Safari/Data/Library/Safari` | iCloud Tabs (this Mac left out; positions are zlib JSON) |

`SafariStore` reads them (databases from a private copy, since Safari holds them open) and writes Favorites back
into Bookmarks.plist in Safari's binary format, keeping every key it doesn't know and a backup of the last 10 versions
in the feature's data folder. Both folders are watched, so changes show up live.

**Writing like Safari** (from Safari's code, macOS 27):
- **Lock.** Safari and its sync agent lock the file with a `lock` folder next to it, made with mkdir and holding
  `details.plist` (who holds it). The store takes the same lock around each read-modify-write (`SafariFileLock`) and
  takes over abandoned locks, as Safari does.
- **Change log.** Each edit is recorded in the root's `Sync.Changes`, the change log the agent uploads and then clears.
  A record has `Type` (Add, Modify or Delete), `Token` (a new UUID), `BookmarkUUID`, `BookmarkType` (Leaf), and for
  synced items `BookmarkServerID`, plus `DeletedBookmarkSyncData` for a Delete. Without a record, an edit stays on this
  Mac: that's why a deletion never reached the iPhone. Safari's rule for redundant records is kept: a Delete replaces
  pending records, and cancels an Add that never reached iCloud.
- **When it uploads.** The agent doesn't watch the file. It syncs bookmarks when Safari saves its own edits (Safari
  asks over an entitled XPC connection), when iCloud pushes a bookmark change from another device, or when the account
  changes. Records written here wait in the file for the next of these.

**Access, no Full Disk Access** — "Connect to Safari…" (or the start page button) opens an open panel on each
folder; clicking Allow is explicit consent, which macOS honors for Safari's protected data. `SafariAccess` keeps the
grants as security-scoped bookmarks (`Grants/` in the feature's data folder), so it's two clicks once. Cancelling the
second panel keeps Favorites and history. "Disconnect from Safari" stops using Safari's folders and deletes the
stored grants.

**Status (macOS 27, real data, 2026-10-15)** — Reading: verified, including a favorite added on the iPhone (it
reached this Mac's Bookmarks.plist and `SafariStore.favorites()`, which the start page lists) and the iPhone's
iCloud Tabs. Adding a favorite: verified on the iPhone within
two minutes, with Safari running on the Mac (Safari watches Bookmarks.plist and hands the change to its sync agent);
with Safari not running, untested. Deleting: **not offered yet**. A favorite removed from the file without a change
record never left the Mac. The store now writes the record, but it hasn't been verified on the iPhone, so delete in
Safari for now. Tabs and history are read-only: their stores belong to Safari's agents.

**Import** — offers Safari to the import sheet (`BrowserImportSource`): every bookmark except the Reading List
(Favorites as a folder) and the history, through the same folder grants (asked for if needed).

**Commands** — `safari.add-favorite`, `safari.cloud-tabs`, `safari.connect`, `safari.disconnect`.
**Settings** — `safari.enabled`.

**Tests** — `./forkctl test safari` (fixtures in Safari's formats, including real-schema CloudTabs.db and Safari's
position blobs; grants through a fake panel).

**Remove it** — `./forkctl feature disable safari`.
