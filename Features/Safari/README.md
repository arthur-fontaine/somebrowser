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
- **When it uploads.** The agent doesn't watch the file. It syncs bookmarks when Safari asks over an entitled XPC
  connection, when iCloud pushes a bookmark change from another device, or when the account changes. Safari asks
  after saving its own edits. It also asks when it receives the agent's distributed notification
  `com.apple.SafariBookmarksSync.UpdateReceived` with `syncResult` 5 while it holds change records, and records it
  loaded from the file count. Safari reloads the file as soon as it changes (FSEvents). Such a reload forgets the loaded
  change log when the bookmarks themselves changed, and keeps it when only sync data did. So after an edit,
  `SafariStore.upload` does three things:
  1. touches the file, which makes Safari reload again and keep the records;
  2. posts the notification;
  3. repeats at growing intervals until the change log is empty.

  Result 5 also starts Safari's CloudKit migration, so the store only posts it when `CloudKitMigrationState` is 3.
  Verified 2026-10-15 on macOS 27 with real data: the agent uploaded an added favorite in under a second
  ("Assigning new record … to locally added item", then "Cleared 1 changes"). With Safari closed, the records wait
  for its next sync.

**Access, no Full Disk Access** — "Connect to Safari…" (or the start page button) opens an open panel on each
folder; clicking Allow is explicit consent, which macOS honors for Safari's protected data. `SafariAccess` keeps the
grants as security-scoped bookmarks (`Grants/` in the feature's data folder), so it's two clicks once. Cancelling the
second panel keeps Favorites and history. "Disconnect from Safari" stops using Safari's folders and deletes the
stored grants.

**Status (macOS 27, real data, 2026-10-15)** — Reading: verified, including a favorite added on the iPhone (it
reached this Mac's Bookmarks.plist and `SafariStore.favorites()`, which the start page lists) and the iPhone's
iCloud Tabs. Adding a favorite: verified on the iPhone within
two minutes, with Safari running on the Mac (Safari watches Bookmarks.plist and hands the change to its sync agent);
with Safari not running, untested. An added favorite's upload was also verified on its own: in the agent's log,
within a second of the edit. Deleting: **not offered yet**, until a Delete record is seen uploaded the same way.
Tabs and history are read-only: their stores belong to Safari's agents.

**Live lab** — `Tests/LiveSafariLab.swift`, off by default, edits the real Bookmarks.plist through the store, only on
favorites named "<Brand.name> lab…": `SAFARI_LAB="add:<name>"`, `"remove:<name>"` or `status`, then
`swift test --filter safariLab`; read the agent with `log show --info --predicate 'process == "SafariBookmarksSyncAgent"'`.

**Import** — offers Safari to the import sheet (`BrowserImportSource`): every bookmark except the Reading List
(Favorites as a folder) and the history, through the same folder grants (asked for if needed).

**Commands** — `safari.add-favorite`, `safari.cloud-tabs`, `safari.connect`, `safari.disconnect`.
**Settings** — `safari.enabled`.

**Tests** — `./forkctl test safari` (fixtures in Safari's formats, including real-schema CloudTabs.db and Safari's
position blobs; grants through a fake panel).

**Remove it** — `./forkctl feature disable safari`.
