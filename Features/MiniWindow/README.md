# Mini Window

**Purpose** — Arc's Little Arc: links from other apps open in a small, sidebar-less window you can promote into your main window.

**How it works** — the window opens centered on the pointer, on its screen, floating above every app and joining
whichever Space shows there, full-screen ones included (`BrowserWindowPlacement`, applied as the shell creates it). It is
Quick Look's window, measured: a 38 pt bar with close and zoom, the site, Share and Open in Main Window, and the page
card 6 pt inside the edges with 14 pt corners (`cardInset`, `cardRadius`). Closing the page (⌘W) closes the window.

**Commands**
- `mini-window.new` — New Mini Window (cmd+opt+n)
- `mini-window.move-to-main` — Move to Main Window (cmd+opt+o)

**Settings**
- `mini-window.forExternalLinks` — Open links from other apps in a mini window

**Tests** — `./forkctl test mini-window`.

**Remove it** — `./forkctl feature disable mini-window`.
