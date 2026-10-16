# Picture in Picture

**Purpose** — Radian's system-wide PiP: leave a playing video and it floats over every app; fling it to a corner with the trackpad, tuck it into an edge, control it without coming back.

**How it works**
- Leaving a tab whose video plays (or a video call) pops its page into `PiPPanel`, a non-activating
  floating `NSPanel` on every Space. Regular videos switch to a video-only presentation (injected CSS);
  calls keep their page (Meet's own controls).
- The page content comes from the engine through `EngineFloating` (WebKit moves the `WKWebView`; CEF
  hands over the tab's own window), so playback never restarts.
- `PiPPhysics` (pure, tested): throw projection `p + v·d/(1−d)`, nearest-corner snap, edge stash,
  aspect-preserving pinch resize, and the settle: a spring that starts at the release's velocity (so a throw carries
  on into its corner) and that fingers can catch mid-flight. Mouse drag, two-finger trackpad moves and pinch all feed
  it. Moves stop at the screen's edges (a throw past one tucks the panel in). Trackpad moves follow the fingers whatever the
  scroll direction setting, a little further than they travel, and carry the pointer with the panel (else it slides
  out from under it); pinches are caught over the panel by event monitors
  (AppKit sends them to the key window, and the panel never takes focus), in this app and over others.
- Controls: close, mute, expand back to the tab, −10s/play/+10s, scrubber.
- Selecting the tab again closes the panel; a "Pop-out View" toggle appears in Site Controls.

**Commands** — `pip.toggle` (⌃⌘P), `pip.close`. **Settings** — `pip.autoPopOut`, `pip.calls`, `pip.width`.

**Tests** — `./forkctl test pip`.
