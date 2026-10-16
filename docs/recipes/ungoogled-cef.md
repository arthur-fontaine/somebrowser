# Recipe — our CEF (Chromium) source build

The browser runs on CEF. Upstream's `Engines/CEF/vendor.json` pins a prebuilt CEF; ours is built from source with our
patches (`Engines/CEF/patches/`) by `Engines/CEF/build/build-cef.sh`. The idle-profile E2E net-log test enforces that
an idle browser contacts no one, whichever build runs.

## What the build adds

- Chromium 156 (CEF branch 8078; Chrome stable is 156, and CEF skipped 155): official build, ThinLTO, Chrome's PGO
  profile for this branch on Apple silicon, V8's builtins profiles.
- H.264/AAC/HEVC (`proprietary_codecs`, `ffmpeg_branding=Chrome`); licensing is yours to check.
- Widevine compiled in. It's fetched only with the engine option `protectedMedia: chromium`, and then the component
  updater fetches nothing else. By default DRM pages play in WebKit with FairPlay (ADR-0004).
- Patches:

  | Patch | Effect |
  |---|---|
  | `chromium/0001` | Extension badges exposed to accessibility, so they show on the sidebar's pinned actions |
  | `chromium/0002` | `--disable-webui-omnibox`: no hidden AI-mode omnibox popup (one renderer per tab) |
  | `chromium/0003` | `--widevine-only-components`: the component updater registers only Widevine |
  | `chromium/0005` + `cef/0002` | `--views-hosted-new-tabs`: a new tab from a page (an extension's `tabs.create`, `windows.create`) opens as a browser of ours the way the page's popups do, so its id lasts, and pages are `normal` windows to extensions (ADR-0005) |
  | `chromium/0006` | With the same switch, a tab group spans pages (`tabs.group` joins each tab in its own page instead of moving it), and Chrome's saved tab groups are off (ADR-0005) |
  | `chromium/0007` | `--enable-features=RootScrollbarAvoidsCorners:inset/<DIP>`: the page's own scrollbar thumb keeps clear of the card's rounded corners (its travel inset at both ends; the track stays full length, clipped by the corners like a classic AppKit scroller) |
  | `cef/0001` | `downloads.download` from an extension's service worker or popup goes to the client instead of being canceled |

  Ours are applied to a fresh checkout before CEF's own patches (CEF's `patcher.py` runs at build time and stops on any
  patch that fails), so each is written against upstream Chromium and checked both ways: it applies, and CEF's patches
  still apply after it.

Measured 2026-10-16, one page open, fresh profile:

| | Renderers | Helpers' memory |
|---|---|---|
| Stock CEF 154 | 3 | 583 MB |
| Ours | 2 | 433 MB |

The app process is unchanged (~105 MB). Switching tabs takes ~3 ms until drawn, as on 154. One difference: after a
page window is shown, a block queued on the main dispatch queue from inside another can wait ~16 ms (Chromium 154:
~4 ms), while the run loop, which delivers input and draws, is free; the E2E budget measures drawing on the run loop.
All E2E and unit tests pass on it.

ungoogled-chromium has no 156 patch set yet (its tags stop at 155), so de-googling comes from build flags, our run-time
switches (`CEFEngine.privacySwitches`) and the net-log test. When ungoogled tags 156, its patches can be applied
before ours (`utils/patches.py apply` with `patches/series`, then `utils/domain_substitution.py`). They remove the
component updater, so Widevine (`protectedMedia: chromium`) would go too.

## Machine

Apple silicon, 16 GB RAM is enough (ThinLTO picks its own link concurrency), 250+ GB free. Xcode with the macOS SDK.
Chromium 156 accepts SDK 15 and up, and Xcode 26.2 built it on macOS 26.0 (CEF documents Xcode 27). The machine also
needs:
- the license accepted (`sudo xcodebuild -license accept`);
- first launch done (`sudo xcodebuild -runFirstLaunch`);
- the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), which ANGLE's shaders need.

A non-standard Xcode location works through `DEVELOPER_DIR`; the script sets it from `XCODE`.

First build on an M1 Pro (8 cores, 16 GB): checkout about 7 minutes (shallow), build 2 h 44 min.

## Steps

1. On the build machine: `CEF_BRANCH=8078 XCODE=/path/to/Xcode.app Engines/CEF/build/build-cef.sh`. It:
   - checks out (once);
   - applies our patches;
   - downloads the PGO profiles;
   - builds the release `cefsimple` target.
2. Package. `make_distrib` copies the framework from `cefclient.app`, and we build only `cefsimple`, so:
   ```sh
   out=$WORK/download/chromium/src/out/Release_GN_arm64
   mkdir -p "$out/cefclient.app/Contents/Frameworks"
   cp -R "$out/cefsimple.app/Contents/Frameworks/Chromium Embedded Framework.framework" "$out/cefclient.app/Contents/Frameworks/"
   cd $WORK/download/chromium/src/cef/tools
   python3 make_distrib.py --output-dir=../binary_distrib --ninja-build --arm64-build --minimal --no-docs
   cd ../binary_distrib && tar cjf <name>_minimal.tar.bz2 <name>_minimal
   ```
3. Publish and pin: `./forkctl release <tag> --cef <archive.tar.bz2>` uploads it to that GitHub release of `origin`
   (with `gh`), then writes the pin:
   ```json
   { "version": "<version>-somebrowser", "url": "https://github.com/<owner>/<repo>/releases/download/<tag>/cef_binary_…", "sha1": "…" }
   ```
   With `--fork`, a fork pins its own build in `Fork/Engines/CEF/vendor.json`. For a local try before publishing, a
   `file://` URL in `Fork/Engines/CEF/vendor.json` works. Then run `./forkctl vendor cef`, `./forkctl build` and
   `./forkctl test --e2e`
   (with `BROWSER_E2E_CEF_PATCHES=0005,0006` once a build has those patches, their E2E check runs too).

## Gotchas met

- Chromium's git server fails over HTTP/2 ("Error in the HTTP2 framing layer"). The script gives the build its own git
  config with HTTP/1.1, which also skips a user's global config (e.g. GitHub routed through an SSH agent that isn't
  there unattended).
- `concurrent_links` can't be set with ThinLTO.
- `v8/tools/builtins-pgo/profiles/*.profile` must be downloaded (the script does).
