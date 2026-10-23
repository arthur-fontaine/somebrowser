# Apple integrations — how to replicate Radian (researched 2026-10-14)

Legend: **[SDK]** checked in Xcode 27 SDK · **[BIN]** checked in system binaries · **[SRC]** open
source · **[INF]** inferred.

## The gating entitlement

Apple Passwords, native Sign in with Apple and iCloud-Keychain passkeys all depend on the managed
entitlement **`com.apple.developer.web-browser.public-key-credential`** (Apple grants it; Chrome
ships with it **[BIN]**). Request it in the developer portal ("Web Browser Public Key Credential
Requests"). Without it these features fall back (see each section). The app must not be
sandboxed.

**Free (Personal Team) signing doesn't help (verified 2026-10-23).** A Personal Team can't put a managed entitlement in
a profile. It doesn't unlock 1Password either: 1Password 8.12 needs a signed browser in `/Applications` and added under
Settings → Browser → Add Browser. It saves a requirement in `browsers.other-trusted-apps` (its `settings.json`) that
accepts only distribution leaf certificates: App Store, TestFlight or Developer ID (`6.1.9`, `6.1.3`, `6.1.6`,
`6.1.25.1`, `6.2.6` + `6.1.13`). An Apple Development leaf (`6.1.2`, `6.1.12`) passes the team clause and fails that
one, so the helper answers `BrowserVerificationFailed` and the extension falls back to its own web sign-in (which works
since `cef/0003`; before it, `Origin: null` on the extension's fetches made 1Password's servers answer 5xx). Ad-hoc builds fail
sooner (no code signature to read). Both need the paid program: Developer ID for 1Password, plus Apple's grant for the
entitlement.

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

- **Verified 2026-10-14:** spawning the helper from an unentitled process ends in
  `SIGKILL (Code Signature Invalid)`, CODESIGNING "Launch Constraint Violation". The entitlement has its own
  request form, submitted by the Account Holder ([Apple forum](https://developer.apple.com/forums/thread/829169)).
  Radian's "AutoFill for 'Radian'" prompt is this helper's string: Radian holds the entitlement.
- Wire details that differ between the two references (we follow bromure, which spawns the helper directly):
  PROTO `[0,1]`, `msg`/`payload` as JSON strings, bare-hex `SDATA`, full 32-byte session key.

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

- **Verified 2026-10-15** (ad-hoc, unentitled app): `+canPerformAuthorizationWithURL:responseCode:useInternalExtensions:YES`
  is YES for `appleid.apple.com/auth/authorize`; `-beginAuthorizationWithURL:httpHeaders:httpBody:` then answers
  `authorizationDidNotHandle:`. From a non-AppKit process it crashes setting up the remote view controller, so the
  sheet is an `NSViewController` the app must host. Implemented as `Features/SignInWithApple` with a web fallback.

## 3. Safari ⇄ iPhone sync

Radian (08-07 thread): "no Full Disk Access – uses iCloud for sync – setup takes 2 clicks; bookmarks sync on
change; tabs are pushed while your iPhone is locked". No write-up was published; what follows was established here.

- Every system route needs a private entitlement **[BIN]**: `SafariBookmarksSyncAgent` rejects XPC clients without
  `com.apple.private.safari.can-use-bookmarks-sync-agent`; `SafariServices`' `_SFBookmarkCollection` goes through
  `com.apple.SafariServices.xpc`, which wants `com.apple.private.safari.can-read-bookmarks`. No public API in the
  Xcode 27 SDK **[SDK]**.
- iCloud directly is out for tabs and history: Apple lists Safari History, Tab Groups and iCloud Tabs as end-to-end
  encrypted under standard data protection, keys on trusted devices only; only Bookmarks are "in transit & on server"
  ([iCloud data security overview](https://support.apple.com/en-us/102651)).
- So the data comes from the files Safari's agents keep decrypted, and Safari's own sync carries it ("the sync is
  handled by iCloud, so it works the way Safari would"). **No Full Disk Access needed**: choosing the folder in an
  `NSOpenPanel` is explicit consent that macOS honors for Safari's protected data, and a security-scoped bookmark
  keeps it across launches — verified on macOS 27 with a probe app and in the browser **[BIN]**. Two folders, two
  clicks:
  - `~/Library/Safari`: `Bookmarks.plist` (Favorites = `BookmarksBar`, Reading List), `History.db`
    (`history_items`, `history_visits`). The `CloudTabs.db` there is an empty leftover.
  - `~/Library/Containers/com.apple.Safari/Data/Library/Safari`: `CloudTabs.db` (`cloud_tab_devices`: one row per
    device, this Mac included, by computer name; `cloud_tabs`: `position` is zlib JSON
    `{"sortValues":[{"changeID","sortValue","deviceIdentifier"}]}`, `is_pinned`; `cloud_tab_close_requests`),
    `SafariTabs.db` (Tab Groups, iOS-style `bookmarks` table with `server_id`).
- Bookmarks.plist on macOS 27 carries no CloudKit state (`CloudKitMigrationState` 0, no per-item `ServerID`): the
  agent keeps its own record and hears about local edits from Safari (`_userDidUpdateBookmarkDatabase`, over the
  entitled XPC connection). Live round trip (2026-10-15, Safari running): a favorite added to the file reached the
  iPhone in under two minutes — Safari watches the file and reports additions. A favorite removed from the file
  did not: Safari rewrote the file without it, but the agent takes deletions from Safari's change log
  (`copyDeletedBookmarkSyncDataWithChange:`), so the iPhone kept it. Tabs and history stay read-only.
- Implemented as `Features/Safari`.

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
