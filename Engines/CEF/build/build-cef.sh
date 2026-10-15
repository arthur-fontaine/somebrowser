#!/bin/bash
# Builds our CEF (Chromium) from source on a Mac: checkout, our patches, profile-guided optimisation, minimal
# distribution. Run on the build machine (Apple silicon, 16+ GB RAM, 250+ GB free, Xcode with license accepted and
# first launch done, Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`). Takes hours; reruns resume.
#
#   CEF_BRANCH=8078 XCODE=~/Applications/Xcode-26.2.0.app ./build-cef.sh
#
# The archive lands in $WORK/download/chromium/src/cef/binary_distrib/; pin it in Fork/Engines/CEF/vendor.json.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/cef}"
CEF_BRANCH="${CEF_BRANCH:-8078}"   # Chromium 156 (CEF's branches table: chromiumembedded.github.io/cef/branches_and_building)
XCODE="${XCODE:-/Applications/Xcode.app}"
export DEVELOPER_DIR="$XCODE/Contents/Developer"
# A git config of the build's own: Chromium's servers fail over HTTP/2 ("framing layer"), and a user's global config
# may route GitHub through an SSH agent that isn't there unattended.
mkdir -p "$WORK"
printf '[http]\n\tversion = HTTP/1.1\n\tpostBuffer = 524288000\n' > "$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
cd "$WORK"
[ -f automate-git.py ] || curl -sfO https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py
src="$WORK/download/chromium/src"

if [ ! -f "$src/chrome/VERSION" ]; then
  python3 automate-git.py --download-dir="$WORK/download" --branch="$CEF_BRANCH" --arm64-build \
    --no-build --no-distrib --no-chromium-history
fi
export PATH="$WORK/download/depot_tools:$PATH"

# Our patches, once (git apply --check fails when already applied).
for p in "$here"/../patches/chromium/*.patch; do
  (cd "$src" && git apply --check "$p" 2>/dev/null && git apply "$p" && echo "applied $(basename "$p")") || true
done
for p in "$here"/../patches/cef/*.patch; do
  (cd "$src/cef" && git apply --check "$p" 2>/dev/null && git apply "$p" && echo "applied cef/$(basename "$p")") || true
done

# Profile-guided optimisation: Chrome's own profiles for this branch on Apple silicon, and V8's builtins profiles.
(cd "$src" && python3 tools/update_pgo_profiles.py --target=mac-arm update \
  --gs-url-base=chromium-optimization-profiles/pgo_profiles)
(cd "$src" && python3 v8/tools/builtins-pgo/download_profiles.py --depot-tools "$WORK/download/depot_tools" download)

# Official build (ThinLTO, PGO), H.264/AAC, Widevine compiled in (fetched only with --widevine-only-components),
# no debug symbols. ThinLTO picks its own link concurrency (don't set concurrent_links).
export GN_DEFINES="is_official_build=true chrome_pgo_phase=2 proprietary_codecs=true ffmpeg_branding=Chrome \
enable_widevine=true symbol_level=0 blink_symbol_level=0 v8_symbol_level=0"
export CEF_ARCHIVE_FORMAT=tar.bz2
caffeinate -dimsu python3 automate-git.py --download-dir="$WORK/download" --branch="$CEF_BRANCH" --arm64-build \
  --no-update --force-build --no-debug-build --build-target=cefsimple --minimal-distrib-only --build-log-file
