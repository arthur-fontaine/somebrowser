# Archive

**Purpose** — Today tabs you haven't looked at for a while archive themselves (Arc); find them again in the archive.

**Commands**
- `archive.show` — Show Archive (cmd+opt+a)
- `archive.run-now` — Archive Idle Tabs Now

**Settings**
- `archive.after` — Archive Today tabs after
- `archive.keepDays` — Keep archived tabs for (days)

**Sidebar** — once something is archived, Archive in the sidebar's ⋯ menu (its footer) opens it. A click brings a tab back
and shows it; ⌘-click brings it back behind the list, which stays open for the next one.

**Start page** — contributes "Recently Archived": the five tabs archived last, a click from coming back.

**Tests** — `./forkctl test archive`.

**Remove it** — `./forkctl feature disable archive`.
