# Error Pages

**Purpose** — The browser's own page when a site can't be opened (offline, no such site, refused, timed out) and when
its certificate isn't valid, at the address that failed, instead of Chrome's pages (and WebKit's blank one). Try
Again reloads; for a certificate, Go Back, or Visit Anyway, which accepts that site's certificate until the browser
quits.

**How it works** — sets `EngineHooks.errorPage` (Core `PageLoadError`). The Chromium engine answers CEF's
`OnLoadError` (main frame) and `OnCertificateError` (refusing, so the load fails and this page shows; or allowing a
site in `acceptedInvalidCertificates`); the WebKit engine its failed provisional navigations and server-trust
challenges. Visit Anyway is a link to `https://visit-anyway.invalid/?to=…` that a navigation policy takes over, and
only from the certificate page shown for that same site in that tab (a page can't make one up).

**Tests** — `./forkctl test error-pages`; end to end: `EngineConformanceTests.unreachableSitesShowTheBrowsersPage`.
