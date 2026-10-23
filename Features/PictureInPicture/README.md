# Picture in Picture

**Purpose** — Radian's system-wide PiP: leave a playing video and it floats over every app; move it with the trackpad, tuck it into an edge, control it without coming back.

**How it works**
- Leaving a tab whose video plays with sound (as Chrome's automatic PiP: a muted backdrop video stays), or a video
  call, pops its page into `PiPPanel` (never in place of one already floating: only `pip.toggle` replaces it), a non-activating
  floating `NSPanel` on every Space. Regular videos switch to a video-only presentation (injected CSS,
  the video in the top layer so no ancestor's box crops it);
  calls keep their page (Meet's own controls).
- The page content comes from the engine through `EngineFloating` (WebKit moves the `WKWebView`; CEF
  hands over the tab's own window), so playback never restarts.
- The panel flies into the bottom-right corner from the video's own place on the page (`PiPGeometry`), once the page
  shows only the video in its shape (else re-aimed midway, it stuttered). The page stays where it is until then.
- `PiPPhysics` (pure, tested): throw projection `p + v·d/(1−d)`, edge tuck, aspect-preserving pinch resize, and the
  settle: a spring that starts at the release's velocity and that fingers can catch mid-flight (re-aimed, it keeps its
  speed). Placement is free: still fingers leave the panel where it is, a throw glides on and stops at the screen's
  edges, a throw past a side edge tucks it in (a strip showing; double-click brings it back). Never further off screen
  than tucked in, whether moved, thrown or overshooting.
- Mouse drag, two-finger trackpad moves and pinch feed it. Trackpad moves follow the fingers whatever the scroll
  direction setting, a little further than they travel; the pointer stays put. Swipes go to what's under the pointer,
  which the panel leaves as it moves; and all of a swipe's events go to the window it began over. So, while the pointer
  stays: between swipes, `SwipeCatcher`, a small invisible window under the pointer where the panel isn't, takes the
  next ones (over other apps too; no system permission), and a local monitor hands swipes over the browser's own
  windows to the panel first (a page that scrolls doesn't take them). Pinches are caught over the
  panel by event monitors (AppKit sends them to the key window, and the panel never takes focus), in this app and over
  others.
- Controls: close, mute, expand back to the tab, −10s/play/+10s, scrubber.
- Selecting the tab again closes the panel; a "Pop-out View" toggle appears in Site Controls.

- By hand: the address field's Picture in Picture button (while a video plays), `pip.toggle`, or Chromium's "Picture in
  Picture" on a video's context menu (`EngineHooks.pictureInPicture`: that video, here rather than Chrome's window; a video
  in a frame keeps Chrome's).

**Commands** — `pip.toggle` (⌃⌘P), `pip.close`. **Settings** — `pip.autoPopOut`, `pip.calls`, `pip.width`.

**Tests** — `./forkctl test pip`.
