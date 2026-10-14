# Sign in with Apple

**Purpose** — Radian's native Sign in with Apple: "Continue with Apple" dims and blurs the page and shows the system's
sheet (account, Continue with Touch ID) in the window; the site then gets Apple's answer, with no appleid.apple.com
window.

**How it works** — A navigation policy takes `https://appleid.apple.com/auth/authorize` (main frame, redirects and
popups alike) to Apple's AppSSO (`SOAuthorization`, as Safari/WebKit do), driven through the Objective-C runtime
(`AppSSOProvider`). Apple's response is loaded with `EngineTab.loadSimulated`, so the page has appleid.apple.com's
origin and the site's own script (form_post, popup `postMessage`) works unchanged; redirects are followed.

**Requirement** — Apple's Apple ID extension serves only browsers signed with the managed entitlement
`com.apple.developer.web-browser.public-key-credential`. Without it (ad-hoc builds) AppSSO answers "not handled" and
the regular web flow continues, so signing in always works.

**Settings** — `apple-signin.native`.

**Tests** — `./forkctl test apple-signin` (a fake provider for every outcome).

**Remove it** — `./forkctl feature disable apple-signin`.
