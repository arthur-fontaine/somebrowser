# Apple integrations — how to replicate Radian (researched 2026-10-14)

Legend: **[SDK]** checked in Xcode 27 SDK · **[BIN]** checked in system binaries · **[SRC]** open
source · **[INF]** inferred.

## The gating entitlement

Apple Passwords, native Sign in with Apple and iCloud-Keychain passkeys all depend on the managed
entitlement **`com.apple.developer.web-browser.public-key-credential`** (Apple grants it; Chrome
ships with it **[BIN]**). Request it in the developer portal ("Web Browser Public Key Credential
Requests"). Without it these features fall back (see each section). The app must not be
sandboxed (Safari sync needs Full Disk Access anyway).

## 1. Apple Passwords (autofill, save, generation)

- Apple's native-messaging host
  `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app`
  (the one the iCloud Passwords Chrome extension uses) contains Radian's exact prompts
  ("AutoFill for “%@”", "Save Password?") **[BIN]**.
- Launch constraint: parent must hold the entitlement above, or be one of ~40 allow-listed
  browsers **[BIN]**. Spawn it from the main (entitled) process; argv[1] = the extension origin
  `chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/`; stdio with 4-byte LE length + JSON.
- Protocol (reverse-engineered: `au2001/icloud-passwords-firefox`, `rderaison/bromure`
  `iCloudPasswordsBridge.swift`): cmd 14 capabilities; cmd 2 SRP-6a handshake (3072-bit, SHA-256,
  g=5); then AES-128-GCM "SMSG": cmd 4 login names for URL (dropdown), cmd 5 password for login
  (helper shows Touch ID prompt), cmd 6 save/update (helper shows native "Save Password?" and writes
  to Passwords), cmd 16/17 one-time codes, cmd 9/10 disabled/re-login. First pairing shows a 6-digit
  PIN from the helper; persist the session key.
- **Generation (user requirement: must rely on Apple Passwords):** use Apple's public generator
  `SecCreateSharedWebCredentialPassword()` **[SDK]** (Security framework, macOS 11+) and save the
  result through cmd 6 into the Passwords app. (The helper has no generate command; Apple's modern
  `ASGeneratePasswordsRequest` is iOS-only **[SDK]**.)
- Our part: form detection + dropdown + fill injection (content script → process message).
- Shortcut on Chrome-style CEF: install the real iCloud Passwords extension and write
  `NativeMessagingHosts/com.apple.passwordmanager.json` into the profile (Phi Browser does this).
- Public APIs that do NOT work for arbitrary sites: `SecAddSharedWebCredential`,
  `ASAuthorizationPasswordRequest` (own associated domains only), `ASCredentialDataManager`
  (iOS-only), keychain internet passwords (private access groups).

## 2. Sign in with Apple (native sheet + Touch ID)

- Not `ASWebAuthenticationSession` (callback must be our associated domain) and not
  `ASAuthorizationAppleIDProvider` (tokens for our own Services ID).
- Real mechanism: private **AppSSO** — WebKit's `SOAuthorizationCoordinator` →
  `SOAuthorization canPerformAuthorizationWithURL:…` → `AKAppSSOExtension_macOS.appex`, which only
  serves callers with `com.apple.developer.web-browser` or the public-key-credential entitlement
  **[BIN]**. Completion returns the HTTP response (incl. `form_post` HTML) to load into the tab.
- WKWebView engine: works automatically with the entitlement (`ExtensibleSSOEnabled`) **[INF]**.
- CEF engine: intercept `https://appleid.apple.com/auth/authorize` (`OnBeforeBrowse`/`OnBeforePopup`),
  `dlopen` AppSSO, drive `SOAuthorization` (signatures from WebKit `AppSSOSPI.h`), serve the
  returned body via a resource handler; on "not handled" fall back to the web flow.

## 3. Safari ⇄ iPhone sync

- Data needs **Full Disk Access** (deep-link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`).
- `~/Library/Safari/Bookmarks.plist` (Favorites = `BookmarksBar`, `BookmarksMenu`, Reading List;
  `WebBookmarkUUID`, per-item `Sync`), `History.db` (`history_items`, `history_visits`,
  `history_tombstones`), `Containers/com.apple.Safari/Data/Library/Safari/CloudTabs.db`
  (`cloud_tab_devices`, `cloud_tabs`), `SafariTabs.db` (profiles, tab groups).
- Read: FSEvents on directories (atomic replace), SQLite read-only/immutable or copy with
  WAL, debounce + diff by UUID/URL. Optional AppleScript `sync all plist to disk`.
- Write (mandatory, Radian does it): only AppleScript `add reading list item` is a documented route.
  Bookmark/favorite write-back goes through `Bookmarks.plist` edits coordinated with
  `SafariBookmarksSyncAgent` (backups first, verify round-trip to iPhone experimentally and lock
  the working recipe into an integration test).

## 4. System-wide PiP

- AVKit sample-buffer PiP exists on macOS but has no mute/custom controls/stash; video-call PiP
  controller is iOS-only **[SDK]**.
- Custom `NSPanel` (`.nonactivatingPanel`, `.floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary, .ignoresCycle]`, `hidesOnDeactivate = false`) with SwiftUI controls driven by JS
  (`currentTime ± 10`, `muted`, `paused`).
- Video source in CEF: Document Picture-in-Picture (`CEF_WOD_NEW_PICTURE_IN_PICTURE`,
  `--enable-blink-features=DocumentPictureInPictureCefOptions`), or move the tab's view into the
  panel in "video only" mode. Meet already uses Document PiP.
- Physics: `NSPanGestureRecognizer` velocity → projected point `pos + v·d/(1−d)`, d≈0.998/ms;
  snap to nearest corner of `visibleFrame`; projected past an edge ⇒ stash with a sliver;
  two-finger moves via `scrollWheel` phases; spring animations.

## 5. Touch ID

- Gate: `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` falling back to
  `.deviceOwnerAuthentication`; `touchIDAuthenticationAllowableReuseDuration`.
- Protect secrets: keychain items with `SecAccessControlCreateWithFlags(.biometryCurrentSet)` +
  `kSecUseDataProtectionKeychain`; or `LARight`.
- Passkeys: Chromium already uses `ASAuthorizationWebBrowserPublicKeyCredentialManager` when the
  entitlement is present; pass an authenticated `LAContext` via
  `ASAuthorizationWebBrowserExternallyAuthenticatableRequest.authenticatedContext`.
