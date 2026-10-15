# Radian (@oleksiibe) — feature inventory, 17 Jul 2026 → now

Source: every original post from https://x.com/oleksiibe since 2026-07-17, plus his
replies that carry product information (last checked 2026-10-15 with X search over 07-16→08-14 and 08-13→now: the
original posts are exactly the rows below, nothing new after the 10-01 PiP post; 08-07's
first reply on Safari sync — "no Full Disk Access, uses iCloud for sync, setup takes 2 clicks" — is covered in
`apple-integrations.md`). Videos were inspected frame by frame.
Radian is a native macOS (Swift/AppKit/SwiftUI) Chromium browser by Oleksii.

| Date | Post | What it shows |
|---|---|---|
| 07-17 | "instant hitbox state with spring animations" | Vertical tab list. Hover highlight ("hitbox") follows the cursor instantly; insert/close of rows animates with springs; the row under the cursor is highlighted immediately after a close even though rows are still moving. Close "×" appears on hover. "Add Tab" row at top inserts new tab with a spring. |
| 07-28 | "first Chromium browser to ever support Apple Sign in with Touch ID" | Clicking "Continue with Apple" on a site: page blurs/dims, a native in-window "Sign in with Apple" sheet appears (account row, "Continue with Touch ID"), states Signing in… → Done ✓, page un-blurs and is logged in. No appleid.apple.com popup window. |
| 08-07 | "first external browser to sync history, tabs, and bookmarks with Safari on your iPhone" | Start page shows a Favorites grid that updates live when favorites are added on iPhone Safari, and deleting on Mac (context menu: Open in New Tab / Open in New Window / Copy / Delete) removes it on iPhone. "iCloud Tabs" button on the start page lists the iPhone's open tabs ("<name>'s iPhone"); click opens it. History also synced. Bi-directional. |
| 08-13 | "switch to Radian with all your data" | Onboarding "Make it easier to switch": import bookmarks, history and extensions from Arc, Atlas, Chrome, Dia, Helium, Safari. |
| 08-18 | "radian supports apple passwords natively" | Focusing a login field shows a native autofill dropdown listing Apple Passwords entries for the site; choosing one triggers the system "AutoFill for 'Radian' — Touch ID or enter your password" prompt, then fills username+password. |
| 08-27 | "generates & saves your passwords in the passwords app" | On sign-up forms: "Use Strong Password" suggestion (Passwords-app styled) fills a generated password; after submit a native "Save Password?" prompt (Save Password / Not Now) stores it in Apple Passwords. Apple Passwords is the default built-in password manager. |
| 09-08 | "Readable Downloads … Apple Intelligence" | **Excluded by the user (download renaming).** Still worth keeping the motion: file icon flies from the page into the toolbar downloads button, and a download toast slides out above the toolbar. |
| 09-16 | "a browser that moves with you" | Arc-like sidebar: favorites tiles on top, "Archive", "Add Tab", tab list, bottom bar (profile avatar, space dots, archive). Top toolbar (sidebar toggle, back, site-controls button, URL pill) hides when scrolling down and reappears when scrolling up / hovering the top edge (iOS-Safari-like). The URL field can live in the sidebar. Two-finger horizontal swipe switches Spaces with a fast interactive slide (each space has its own gradient + tabs). |
| 09-22 | "hej hej" | Photos (Mac Studio); no feature. |
| 09-24 | "its okay to make something feel slightly nicer" | Site-controls popover from the URL pill: "Connection is Secure", toggles Camera / Microphone / Sound / Pop-out View, "Data and Cookies 7.4 MB", "Permissions". Spring-in popover, animated toggles, icons morph with state (speaker waves). |
| 10-01 | "PiP the way it had to be" | Switching away from a tab that plays video pops it into a floating, system-wide PiP window (over the desktop, outside the browser). Trackpad: drag + fling with momentum snaps to screen corners, can be tucked/stashed against an edge. Hover controls: close, mute, expand back to tab, −10s / play-pause / +10s, scrubber. Same for Google Meet: leaving the tab pops out a call PiP with Meet controls (mic, camera, present, emoji, raise hand, hang up). |

Relevant replies:

- 09-17: Arc's Peek is "already scheduled, and it will be called **Radian Preview**".
- 09-17: "Radian will stay macOS only, because of deep integration with the system and the graphics".
- 09-24: plans to open-source two layers: **Security Core** — a bundled, inspectable component that
  independently verifies outbound connections ("verify where your data goes") and *holds sensitive
  permissions itself* (camera, mic, etc. are granted to Security Core, not to the browser);
  and **ChromeKit** — a framework to build a Chromium browser in native Swift (comparable to
  OpenAI's OWL and The Browser Company's ADK).
- 09-24: free; will hand out builds in batches.

## Derived requirement list (all except download renaming)

1. Spring-animated vertical tab list with instant hover hitbox.
2. Sign in with Apple handled natively with Touch ID (no web popup).
3. Bi-directional Safari sync: favorites/bookmarks, iCloud Tabs (open tabs), history.
4. Importer: Arc, Atlas, Chrome, Dia, Helium, Safari (bookmarks, history, extensions).
5. Apple Passwords autofill (system auth prompt, Touch ID).
6. Strong password generation + "Save Password?" into Apple Passwords; Passwords is the default manager.
7. Download fly-to-toolbar animation + download toast (no renaming).
8. Sidebar with favorites, archive, spaces; space switching by trackpad swipe.
9. Scroll-aware auto-hiding toolbar, hover-to-reveal; URL field movable to the sidebar.
10. Site-controls popover (security, camera, mic, sound, auto-pop-out, site data size, permissions).
11. System-wide PiP (video + video calls), trackpad fling to corners, edge stash, custom controls.
12. Preview (Arc Peek equivalent).
13. Security Core: auditable connection verifier + permission broker.
14. "ChromeKit"-like reusable Swift ↔ Chromium layer.
