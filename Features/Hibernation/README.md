# Tab Hibernation

**Purpose** — keep memory and CPU low with many tabs open: a background tab you haven't looked at for a while
(default 1 hour) frees its page, and when macOS reports memory pressure background tabs are freed right away (a
warning frees those idle for 5 minutes, critical frees all). A hibernated tab keeps its URL, title, favicon and
back/forward history, shows dimmed in the sidebar, and reloads when selected.

**How it works** — a 60-second timer (with tolerance, so it coalesces with other wakeups) and a
`DispatchSource` memory-pressure source call `BrowserRuntime.discard`, longest idle first. Idle time is
`BrowserTab.lastActiveAt`, which Core stamps when a tab is selected and when it's left.

Never hibernated: tabs shown in a window, tabs a feature holds awake (`BrowserRuntime.holdAwake`, e.g. picture in
picture), pages playing sound or video, pages using the camera or microphone, and pages you typed into (a small
script reports typing; the tab stays awake until it navigates), so a half-written form is never lost.

**Commands** — `hibernation.hibernate-background` (Tabs menu, command bar): hibernate every background tab now.
**Settings** — `hibernation.after` (5m … 4h, never), `hibernation.memoryPressure`.

**Tests** — `./forkctl test hibernation` (idle threshold, busy, held and edited tabs, settings, memory pressure
levels, command); E2E on both engines (woken tabs keep their history; edited tabs aren't hibernated).

**Remove it** — `./forkctl feature disable hibernation`; tabs then stay loaded until closed.
