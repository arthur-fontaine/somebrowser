# Somebrowser

A native macOS browser — SwiftUI shell, Chromium (CEF) or WebKit engine — built to be **forked and
customized**, by you or by an agent.

- **Feels native**: a real `NSWindow` with an Arc-style sidebar (traffic lights, address pill,
  favorites, pinned/Today tabs), native menus generated from every command, native settings.
- **Tab tree** (Horse): links you open become children of the page that opened them; close a parent
  and its children are promoted; ⌘⇧T brings back the whole branch.
- **Keyboard first** (Arc): ⌘T command bar for URLs, search, open tabs, history and every action;
  every command has a remappable shortcut.
- **Almost full-screen** with ⌘S: the sidebar hides, the left edge reveals it, a slim toolbar follows
  your scroll direction (Radian).
- **Private by default**: DuckDuckGo search, no Google services unless you pick them.

See `TODO.md` for the full feature inventory and progress, `docs/` for research and decisions.

## Build

Requirements: macOS 26+, Xcode 26+ (Swift 6.2+).

```sh
./forkctl run            # build and launch (WebKit engine by default)
./forkctl test           # all unit/integration tests
./forkctl vendor cef     # download Chromium (CEF) for the Chromium engine
./forkctl engine use cef-chrome
```

## Fork it

```sh
./forkctl rename "Kestrel" --bundle-id dev.me.kestrel
./forkctl icon ~/Desktop/kestrel.png
./forkctl feature disable toolbar
./forkctl feature new reading-list --fork
```

All of these write only to `Fork/`, so pulling upstream never conflicts. Agents: read `AGENTS.md`.
