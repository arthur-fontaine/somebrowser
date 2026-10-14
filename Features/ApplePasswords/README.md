# Apple Passwords

**Purpose** — Apple Passwords is the browser's password manager: AutoFill dropdown on login fields, macOS's
Touch ID prompt before filling, "Use Strong Password" from Apple's generator (`SecCreateSharedWebCredentialPassword`),
and the native "Save Password?" sheet writing to the Passwords app.

**How it works** — Talks to Apple's `PasswordManagerBrowserExtensionHelper` (the iCloud Passwords extension's
native host): SRP-6a pairing with the code it displays, then AES-GCM messages (`PasswordsSession`, `PasswordsClient`).
A page script (both engines) detects fields, forwards keys while the menu is open, and reports submits.

**Requirement** — macOS starts the helper only under a browser signed with Apple's managed entitlement
`com.apple.developer.web-browser.public-key-credential` (request form, Account Holder role). Signed builds carry it
(`Defaults/Entitlements.plist`); ad-hoc builds show "unavailable".

**Commands** — `passwords.open-app`, `passwords.connect`. **Settings** — `passwords.enabled`, `passwords.offerToSave`,
`passwords.suggestStrong`.

**Tests** — `./forkctl test passwords` (vectors from an independent reference, full flows against a fake helper).

**Remove it** — `./forkctl feature disable passwords`.
