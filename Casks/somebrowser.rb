cask "somebrowser" do
  version :latest
  sha256 :no_check

  # `forkctl release v<VERSION> --app` uploads the DMG under this name to every release.
  url "https://github.com/arthur-fontaine/somebrowser/releases/latest/download/SomeBrowser.dmg"
  name "Some Browser"
  desc "Native browser with a SwiftUI shell and a Chromium or WebKit engine"
  homepage "https://github.com/arthur-fontaine/somebrowser"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Some Browser.app"

  # Not notarized: Gatekeeper refuses to launch it while quarantined.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Some Browser.app"]
  end

  uninstall quit: "dev.somebrowser.browser"

  # Leaves ~/Library/Caches/somebrowser-vendor, the engine builds a checkout of
  # this repo downloads.
  zap trash: [
    "~/Library/Application Support/Some Browser",
    "~/Library/Caches/Some Browser",
    "~/Library/Caches/dev.somebrowser.browser",
    "~/Library/Caches/dev.somebrowser.browser.helper",
    "~/Library/HTTPStorages/dev.somebrowser.browser",
    "~/Library/Preferences/dev.somebrowser.browser.plist",
    "~/Library/WebKit/dev.somebrowser.browser",
  ]
end
