# Recipe — an ungoogled CEF build (with H.264/AAC)

The browser ships the prebuilt CEF minimal distribution pinned in `Engines/CEF/vendor.json` and keeps it quiet at run
time (ADR-0001, `CEFEngine.privacySwitches`: the idle-profile E2E net-log test proves an idle browser contacts no one).
A source build goes further: Google code paths removed at compile time, proprietary codecs, and our own patches. This
is the recipe; it has not been run end to end in this repository yet (it needs a large Mac, below).

## What you get

- ungoogled-chromium's patches and domain substitution: no Google endpoints compiled in.
- `proprietary_codecs` + `ffmpeg_branding="Chrome"`: H.264/AAC playback (licensing is yours to check).
- Our patches (to write; tracked in `TODO.md`): drop the hidden omnibox's AI-mode popup WebUI (~50 MB renderer), expose
  `ExtensionAction` badge text to CEF (sidebar badges).

## Machine

Chromium does not fit GitHub-hosted runners (≈14 GB disk). Use a self-hosted runner or a rented Mac: Apple silicon,
macOS and Xcode matching CEF's branch requirements, 16+ cores, 32+ GB RAM, 250+ GB free disk. A first build takes hours;
incremental rebuilds after a patch change are much faster on the same machine.

## Steps

1. Read the pinned version: `Engines/CEF/vendor.json` → today `154.0.34+g14c5a08+chromium-154.0.8037.98`. The CEF
   branch is the one whose builds carry that Chromium version (CEF's branches table:
   https://github.com/chromiumembedded/cef/wiki/BranchesAndBuilding). Use ungoogled-chromium's tag for the same
   Chromium version (`154.0.8037.98-*`).
2. Check out without building:
   ```sh
   mkdir -p ~/cef && cd ~/cef
   curl -O https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py
   python3 automate-git.py --download-dir=$PWD/download --branch=<branch> --arm64-build --no-build --no-distrib
   ```
3. Apply ungoogled-chromium to `download/chromium/src` (its `utils/prune_binaries.py`, `utils/patches.py apply` with its
   `patches/series`, `utils/domain_substitution.py`), then the CEF adjustment patch from
   `nmlynch94/com.adamcake.ungoogled_cef.BaseApp` (`ungoogled-chromium-adjust-for-cef.patch`) and its `gn_args.py`
   change (`enable_widevine`/`enable_rlz`). Expect to refresh hunks when versions differ from theirs. Then our patches.
4. Build the minimal distribution without updating the patched tree:
   ```sh
   export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome chrome_pgo_phase=0 \
     symbol_level=0 enable_widevine=false enable_rlz=false"
   export CEF_ARCHIVE_FORMAT=tar.bz2
   python3 automate-git.py --download-dir=$PWD/download --branch=<branch> --arm64-build --no-update \
     --minimal-distrib --no-debug-build --force-build
   ```
   The archive lands in `download/chromium/src/cef/binary_distrib/` as `cef_binary_<version>_macosarm64_minimal.tar.bz2`.
5. Publish it (a release of your fork) and pin it in your fork, never in upstream's file:
   ```json
   // Fork/Engines/CEF/vendor.json
   { "version": "<version>-ungoogled", "url": "https://…/cef_binary_…_macosarm64_minimal.tar.bz2", "sha1": "<shasum -a 1>" }
   ```
   `./forkctl vendor cef` then downloads, verifies and links it instead of upstream's build (`Vendor.cefPin`).
6. `./forkctl build`, `./forkctl test --e2e` (the net-log test still applies; extension tests check the Web Store
   install path still works, since ungoogled patches may touch it).

## Keeping up

Each CEF bump in upstream's `vendor.json` means a new source build: same steps with the new branch and ungoogled tag.
Keep the patch set in your fork (`Fork/patches/…`) so it merges like everything else under `Fork/`.
