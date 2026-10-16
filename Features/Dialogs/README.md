# Page Dialogs

**Purpose** — Pages' `alert`, `confirm`, `prompt`, "Leave this page?" (`beforeunload`) and sites' sign-ins (HTTP
authentication) in the browser's own dialog: a glass card over the tab's page, the page dimmed behind it. Chrome's
and WebKit's own dialogs never show. A dialog waits for its tab to be shown; Return accepts, Escape cancels.

**How it works** — sets `EngineHooks.pageDialog` (Core `PageDialog`). The Chromium engine answers CEF's
`CefJSDialogHandler` and `GetAuthCredentials` through it, the WebKit engine its `WKUIDelegate` panels and HTTP
authentication challenges. A page that goes away answers its dialogs no.

**Without it** — on Chromium a site's sign-in is cancelled (the engine always hands sign-ins to the browser
rather than Chrome's prompt); JavaScript dialogs fall back to Chrome's.

**Commands** — `dialogs.accept` (arguments `text`, or `username` and `password`), `dialogs.cancel` (automation and
the keyboard).

**Tests** — `./forkctl test dialogs`; end to end: `EngineConformanceTests.pageDialogsAreTheBrowsers`.
