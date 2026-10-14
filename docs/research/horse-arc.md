# Horse (browser.horse) and Arc — feature inventory (researched 2026-10-14)

Labels: **[R]** primary source (site, manual, changelog, help center, release notes),
**[R3]** third-party, **[I]** inference. Neither app was installed.

## 1. Horse — the tab tree ("Trails")

Glossary: **Trail** = a node (page) replacing tabs · **Subtrail** = child opened from a page ·
**Sidetrail** = sibling · **Trailhead** (ex-"Area") = top-level container · **Folder** · **Note**.

### Creation
- A link click never navigates in place: it opens a Subtrail right under the current page. [R]
- Nesting comes only from "which page opened which". [R]
- Enter on a focused link branches too. [R]
- "Trails 3": observes SPA route changes/redirects/aliases to decide branch vs replace; links in
  app-like sites (GitHub) branch; "Sign in with…" branches; image clicks open lightbox. [R]
- Dedup: opening a URL already in the Trail focuses the existing node (incl. aliases). Duplicate
  on purpose: ⌘⇧D. [R]
- ⌘Y toggles a Trail to "Open links in current Trail" (tab-like). Settings → Link Behaviour
  Exclusions (prefilled: Twitter, Instagram, Gmail, LinkedIn…) open in place. [R]
- Context menu: Open Link in Subtrail / in New Window / on the Trailhead. [R]
- ⌘T new top-level Trail with search field; ⌘⌥T new child; ⌘⌥⇧T new Sidetrail; "+" on a row =
  child; new Trails go at the top. Links from other apps reuse an existing Trail for the URL. [R]

### Layout
- Vertical sidebar, indented children, ">" chevrons; icon/emoji per node; name = first title,
  rename ⇧⌘L. Row has ••• menu and ×. No global address bar: URL lives on the row (double-click
  or ⌘L to edit). Link-hover box in a corner shows destination, then title+icon, flags
  "already open", doubles as loading indicator. Bottom: find, downloads, history. [R]

### Collapse / close
- ⌘⇧← collapse (or select parent), ⌘⇧→ expand (or select child), ⌥L collapse all others.
  Collapse state per window; tree shared across windows. [R]
- ⌘W deletes a node and **promotes its children in order** [I from changelog]; ⌘⇧W deletes the
  subtree; closing a collapsed parent deletes descendants with an exact-count confirmation. [R]
- ⌘⇧T restores the whole subtree. Lock (⌘⇧K): can't delete, delete → unload. [R]
- Multi-select ⌘-click / ⇧-click, drag selection, Copy as Markdown. [R]

### Drag & drop
- Drop onto a node = child; drop between = sibling; drag out of app = Markdown export;
  ⌘⌥⇧+arrows move nodes (←/→ change level). [R]/[I]

### Other
- The sidebar is the history; Back/Forward walk page history and across followed Trails. [R]
- Autosave everything; multi-window shares one tree; selection/collapse per window. [R]
- Focus Mode ⌘⇧B (only current Trail). The Shelf: hidden sidebar slides out on edge hover. [R]
- Probably Electron [I].

### Horse shortcuts (official)
| Keys | Action |
|---|---|
| ⌘⌥N | New Trailhead |
| ⌘T | New top-level Trail |
| ⌘⌥T | New Subtrail |
| ⌘⌥⇧T | New Sidetrail |
| ⌘⇧D | Duplicate Trail |
| ⌘⇧C | Copy Trail link |
| ⌘L / ⌘⇧L | Edit link / name |
| ⌘⇧K | Lock |
| ⌘W / ⌘⇧W | Delete Trail / with Subtrails |
| ⌘⇧T | Undo delete |
| ⌥L | Collapse all |
| ⌘⇧← / ⌘⇧→ | Collapse/parent · Expand/child |
| ⌘⇧↑ / ⌘⇧↓ | Select above / below |
| ⌘⌥⇧ arrows | Move Trail |
| ⌘Y | Toggle Trail behaviour |
| ⌘S | Toggle sidebar |
| ⌘⇧H / ⌘⇧J | History / Downloads |
| ⌘⇧B | Focus mode |
| ⌘F ⌘G ⌘⇧G ⌘⇧F | Find |
| ⌘0 ⌘= ⌘- | Zoom |
| ⌘[ ⌘] ⌘R ⌘⇧R | Back Forward Reload Hard reload |
| ⌘N ⌃⌘F ⌘⇧I ⌘, ⌘Q | Window, Fullscreen, DevTools, Settings, Quit |

## 2. Arc

Arc is in maintenance mode (Chromium updates only).

### Sidebar (top → bottom)
- Traffic lights + animated Back/Forward/Reload; **URL bar inside the sidebar** with the Site
  Control Center (permissions, Boosts, extensions, PiP toggle, dev mode, capture), copy URL.
- Favorites icon grid (≤12, shared across Spaces, audible ones animate notes).
- Space title (rename, theme, icon, profile; collapse Pinned).
- Pinned tabs + nested Folders above a divider ("/" when navigated away; click favicon resets).
- "+ New Tab" row; Clear (⌘⇧K) with sweep animation.
- Today tabs below the divider, auto-archived after 12 h idle (per profile).
- Bottom bar: Library, Space icons, + menu (Space, Folder, Split, Easel, Boost, Note), media
  tray, downloads.
- Gestures: double-click empty → new tab; drag empty sidebar or the page's top strip → move window;
  drag edge resize, double-click reset, drag fully left hides; inactive window dims sidebar;
  two-finger swipe switches Space.

### Spaces, Folders, Archive
- Spaces: own pinned/today, theme (gradient+grain), icon, profile. ⌃1–9, ⌘⌥←/→, swipe, drag tab
  to move Space. Blank window ⌃⌘N.
- Folders nested, icons, "Copy all links", hover Folder Preview. Folders don't archive.
- Archive searchable via ⌘T "View Archive" / Library. Backups via Help → Restore Data.

### Command Bar (⌘T) / ⌘L
- Centered floating panel (works with sidebar hidden): URL/search, open tabs, history, actions
  (any Arc action by name), site search ("yt" + Tab), ⇧↩ instant link, ⌘⌥⌫ delete suggestion,
  paste-and-go suggestion. ⌘L edits current URL (⌘L ↩ reloads).

### Almost-fullscreen
- ⌘S hides the sidebar: webview fills the window, no toolbar by default; optional toolbar ⌘⇧D.
  Toasts ("New Tab Created") while hidden. Edge hover reveals sidebar overlay [R3].
- Esc prefers website; hold/double Esc exits fullscreen.

### Little Arc, Peek, Split, Boosts, misc
- **Little Arc** (⌘⌥N, ⌘⌥-click): small single-tab window for external links; ⌘O moves it into the
  main window; stays above fullscreen windows.
- **Peek**: links from Pinned/Favorite tabs (or ⇧-click) open in a floating overlay; ⌘O expand,
  Esc/click-outside close, drag-to-dismiss.
- **Split View**: up to 4 panes; ⌃⇧= add, ⌃⇧- close, ⌃⇧1–4 focus; ⌥-click link; drag tab into
  content/onto tab.
- **Boosts**: per-domain colors/fonts/zap elements/custom CSS-JS.
- **Air Traffic Control**: URL rules route links to Spaces.
- **Mini Player**: auto PiP when leaving a playing video; Meet PiP with controls.
- **Ctrl-Tab** MRU switcher (W closes while holding ⌃).
- **Super Copy** ⌘⇧C (strip trackers), ⌘⌥⇧C copy as Markdown.
- Developer Mode for localhost; Capture ⌘⇧2; Reader mode.
- Settings → Shortcuts: everything remappable, per-shortcut "prefer website vs Arc"
  (second press runs the browser action). Tooltips show shortcuts.

### Arc shortcuts (macOS)
Sources: HC help center, N22 official 2022 page, RN release notes, 3P third-party.

| Keys | Action | Src |
|---|---|---|
| ⌘T | New tab / Command Bar | HC |
| ⌘L | Edit current URL | HC |
| ⌘N / ⌃⌘N / ⌘⇧N / ⌥⌘N | Window / Blank window / Incognito / Little Arc | HC RN |
| ⌘W / ⌘⇧T | Close (archive) / Reopen | HC |
| ⌘Z / ⌘⇧Z | Undo/redo sidebar actions | RN |
| ⌘D | Pin/unpin | HC |
| ⌘⇧C / ⌘⌥⇧C | Copy URL / as Markdown | HC |
| ⌘S (⌥⌘B) | Toggle sidebar | HC N22 |
| ⌘⇧K | Clear Today tabs | HC |
| ⌘⇧D | Toggle toolbar | HC |
| ⌘⌥V | Paste URL as new tab | RN |
| ⌘O / ⌘⌥O | Little Arc/Peek → main window / choose Space | HC |
| ⌘1…⌘8, ⌘9 | Sidebar item N / last | HC RN |
| ⌃1…⌃9 | Space N | HC |
| ⌘⌥↑ / ⌘⌥↓ | Previous/next tab | HC |
| ⌘⌥← / ⌘⌥→ | Previous/next Space | HC |
| ⌃Tab / ⌃⇧Tab | MRU switcher | HC RN |
| ⌘[ ⌘← / ⌘] ⌘→ | Back / Forward | HC |
| ⌃⇧= / ⌃⇧- / ⌃⇧1-4 | Split add / close / focus | HC |
| ⌘R / ⌘⇧R / ⌘. | Reload / hard reload / stop | HC RN 3P |
| ⌘F ⌘G ⌘⇧G | Find | HC 3P |
| ⌘+ ⌘- ⌘0 | Zoom | HC |
| ⌘P / ⌘⇧S | Print / Save as | 3P |
| ⌥⌘R | Reader | 3P |
| ⌃⌘F | Fullscreen | 3P |
| ⌘⌥I ⌘⌥J ⌘⌥C ⌘⌥U | DevTools, Console, Inspect, Source | RN 3P |
| ⌃D | Developer Mode | RN |
| ⌘E | Cycle pinned extensions | RN |
| ⌘⇧2 | Capture | RN |
| ⌘Y / ⌘⇧J / ⌘⇧L | History / Downloads / Library | HC 3P |
| ⇧↩ / Tab / ⌘⌥⌫ | (Command Bar) instant link / site search / delete suggestion | HC RN |

Mouse: ⌥-click → split; ⇧-click → Peek; ⌘⌥-click → Little Arc; ⌘/⇧-click tabs multi-select;
⌘-click reload → duplicate; ⌘-click back/forward → new tab; long-press back → history;
⌥-drag duplicate; drag across divider pin/unpin; drag above Space title → favorite; drag into
content → split; drag out → new window; swipe → Space; double-click tab → rename.

### Animation details worth copying
- One control column; content inset with rounded corners in a thin themed frame [I].
- Centered command bar, same with or without sidebar.
- Themed toasts when sidebar hidden; light haptics when dragging tabs.
- Space swipe tracks the finger, settles on a spring [I].
- Peek: floating overlay, drag-to-dismiss. Clear Today: sweep, undoable.
- Hover-link status pill moves away from cursor; full URL after 1.5 s.
- Resize fills with page background colour; animated nav icons.
