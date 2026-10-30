# Safari Sync

**Purpose** — Radian's Safari ⇄ iPhone sync: the start page shows Safari's Favorites and follows Safari's file (so
iPhone changes arrive on Safari's sync schedule); a favorite added here appears in Safari and on the iPhone; the
iPhone's open tabs show on the start page, in the sidebar and in "iCloud Tabs"; Safari's history (iPhone included)
appears in the command bar.

**How it works** — Safari's sync agents (`SafariBookmarksSyncAgent`, `com.apple.Safari.History`) keep what iCloud
syncs in local files, decrypted (History and iCloud Tabs are end-to-end encrypted, so only they can):

| File | Folder | Used for |
|---|---|---|
| `Bookmarks.plist` | `~/Library/Safari` | Favorites (the `BookmarksBar` list), read and written |
| `History.db` | `~/Library/Safari` | Command bar suggestions |
| `CloudTabs.db` | `~/Library/Containers/com.apple.Safari/Data/Library/Safari` | iCloud Tabs (this Mac left out; positions are zlib JSON) |
| `SafariTabs.db` | same | Tab Groups, read-only (folders type 1 / subtype 0 under the root or a profile; tabs are leaves) |

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
stored grants. Sync runs only once connected (`Grants/connected`): importing from Safari (the Import sheet, through
`BrowserImportSource`) asks for Safari's library alone, worded for importing, reads it once and doesn't turn sync on.


**What shows the iPhone's tabs** — CloudTabs.db keeps each tab's `last_viewed_time` (seconds since 2001, 0 when
unset) and each device's type (`com.apple.iphone`…). `SafariModel.recentTabs` is the iPhone's tabs (every device's
when there's no iPhone), last viewed first, once per address.
- The start page has two sections, each movable on its own: "iCloud Favorites" (`safari.favorites`) and
  "iPhone Tabs" (`safari.recent-tabs`, tiles like the favorites; Show All lists the rest in place).
- The sidebar's `sidebar.top` shows up to three viewed in the last three days that aren't open here (`safari.sidebar-tabs`).
  One opened leaves the list, even once its page redirected elsewhere (`handedOff`). The header folds them, which is
  remembered (`SidebarCollapsed` in the data folder); its menu shows every iCloud tab or hides the block.
- iCloud Tabs is a `ListPopover` above its footer button, as History and the archive are: each device's tabs with
  when they were last viewed, then Safari's Tab Groups, searchable. A tab already open here is selected, not opened again.

**Status (macOS 27, real data, 2026-10-15)** — Reading: verified, including a favorite added on the iPhone (it
reached this Mac's Bookmarks.plist and `SafariStore.favorites()`, which the start page lists) and the iPhone's
iCloud Tabs. Adding a favorite: verified on the iPhone within
two minutes, with Safari running on the Mac (Safari watches Bookmarks.plist and hands the change to its sync agent);
with Safari not running, untested. An added favorite's upload was also verified on its own: in the agent's log,
within a second of the edit. Deleting (start page context menu): verified the same way, the agent marked the record deleted in iCloud
within ~20 s.

**This browser on the iPhone** (`SafariSharing.swift`, `SafariWriters.swift`). iCloud Tabs can't carry this browser's
tabs: Safari hands this Mac's open tabs to its agent directly, over the entitled XPC call
`saveTabsForCurrentDeviceWithDictionaryRepresentation:`, and the agent never uploads them from its database. So the
feature takes two other routes:
- **Tabs** (`safari.share-tabs`): a Tab Group named after this Mac (`SafariTabGroupWriter`).
  - Groups and new tabs are written by Safari's own code: WebBookmarks.framework is loaded at run time, and its
    `WBTabGroupManager` (`insertTabGroup:afterTabGroup:`, `updateTabsInTabGroup:completionHandler:`) runs on
    SafariTabs.db.
  - That gives each row what the agent uploads: a CloudKit record and per-attribute CRDT generations in `sync_data`,
    and a server id. Rows written by hand lack them, and the agent skips them ("Ignoring change lacking record", seen
    live 2026-10-15).
  - Closed tabs and removed groups go through WebBookmarks too: `WBTabCollection deleteTabs:` and `deleteTabGroup:`
    (tabs taken from a freshly loaded manager). Each leaves Safari's tombstone: parent -1, the record id, and the
    deletion's generation in `sync_data`.
  - Hand-made tombstones (`deleted` 1 in place) did go up "Deleted". But their deletion generation lost to the
    record's other fields, so the agent recreated the item on its next fetch (seen live). WebBookmarks' own delete
    path `flushDeletedTabsInTabGroup:` waits on Safari, so it isn't used.
  - A tab whose page changed becomes a new tab. Our own group isn't listed among Safari's here.
  - The group is two-way, by iCloud record (`server_id`). The local row id changes when the agent recreates a row
    after another device's change. Tracking it once closed tabs here by mistake, seen live.
  - The feature keeps which record stands for which tab here, from the last mirror (`SharedTabs.json`). A tab keeps
    its row while its record and page are the same.
  - When the agent writes other devices' changes, even with Safari closed:
    - a record gone from the group was closed there. Its tab closes here once a second look 5 s later agrees, since
      the agent may rewrite in two steps, and mirrors leave it out meanwhile;
    - a record this browser didn't write was opened there. It opens here in the background.

    Refreshes that overlap a mirror are skipped. Without a saved map (first run), the browser's tabs set the group.
    The agent appends these changes to `SafariTabs.db-wal`, which a folder watch doesn't see: a close on the iPhone
    took 50 s to show here (seen live). So the WAL itself is watched, and each write rereads only the Tab Groups,
    live rather than from a copy, since the file is tens of MB.
    Safari leaves every group's `order_index` at 0, so groups are read row by row grouped by id. Sorted by tab
    alone, the groups' tabs interleaved, the shared group came out in pieces, and its other tabs looked closed (seen
    live).

Each write is one `BEGIN IMMEDIATE` transaction with a 5 s busy timeout. Private windows are never shared.

**Safari in the background** (`safari.background-sync`, `SafariBackgroundSync`). Only Safari can ask its agents to
sync, so when something written here hasn't reached iCloud and Safari isn't running, the browser launches it hidden
(not activated, no window shown). Things still waiting can be favorites' change records, the shared group's rows, or
visits newer than `last_synced_generation`. Safari's launch syncs Tab Groups, history and bookmarks. The browser quits
it once nothing waits, or after two minutes, unless the user brought it forward. It launches at most once every
15 minutes. If Safari is already running, it syncs with its own activity, and favorites still get the notification.
That notification doesn't start a Tab Groups sync. Tab Groups sync only through the agent call Safari's own saves
make, which is entitled. So while an idle Safari is open, the shared group's edits wait for it, which could be minutes
(seen live 2026-10-15). They went up at its next hidden launch once it had quit.
Verified 2026-10-15 in the app, with Safari quit:
- two pages opened here at 15:27:16;
- at 15:28:05 Safari was launched hidden, uploaded the Mac's group (named after the Mac) with both tabs, and history reached the
  visits' generation;
- Safari was quit again by 15:28:15.
Verified 2026-10-15: a visit written here went up at Safari's next launch (`last_synced_generation` passed it).
Tab Groups verified the same day: a group, its tabs and their removal written here appeared on, then left, the iPhone.

**Running the app on a stand-in Safari** — `BROWSER_SAFARI_HOME=<folder>` makes `<folder>` Safari's home (its
`Library/Safari` and container folders count as picked, so nothing is asked); then run `safari.connect` over the
automation socket.

**Live lab** — `Tests/LiveSafariLab.swift`, off by default, edits Safari's real files through the store. It only
touches items named "<Brand.name> lab…". The verbs are `SAFARI_LAB="add:<name>"`, `"remove:<name>"`, `"group:<name>"`,
`"ungroup:<name>"`, `visit` (one throwaway visit) and `status`, then
`swift test --filter safariLab`; read the agent with `log show --info --predicate 'process == "SafariBookmarksSyncAgent"'`.

**Import** — offers Safari to the import sheet (`BrowserImportSource`): every bookmark except the Reading List
(Favorites as a folder) and the history, through the same folder grants (asked for if needed).

**Commands** — `safari.add-favorite`, `safari.cloud-tabs`, `safari.connect`, `safari.disconnect`.
**Settings** — `safari.enabled`, `safari.sidebar-tabs`, `safari.share-tabs`, `safari.share-history`, `safari.background-sync`.

**Tests** — `./forkctl test safari` (fixtures in Safari's formats, including real-schema CloudTabs.db and Safari's
position blobs; grants through a fake panel).

**Remove it** — `./forkctl feature disable safari`.
