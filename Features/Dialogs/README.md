# Page Dialogs

**Purpose** — Pages' `alert`, `confirm`, `prompt`, "Leave this page?" (`beforeunload`), sites' sign-ins (HTTP
authentication) and the engine's own dialogs (Chrome's extension prompts: a permission asked for, an extension removing
itself) in the browser's own dialog: a glass card over the tab's page, the page dimmed behind it. Chrome's and
WebKit's own dialogs never show. A dialog waits for its tab to be shown; the engine's show over the page in front.
Return accepts, Escape cancels.

**How it works** — sets `EngineHooks.pageDialog` (Core `PageDialog`). The Chromium engine answers CEF's
`CefJSDialogHandler` and `GetAuthCredentials` through it, the WebKit engine its `WKUIDelegate` panels and HTTP
authentication challenges. A page that goes away answers its dialogs no. Chrome's own dialogs (`PageDialog.Kind.engine`:
a title, lines, buttons in Chrome's order) come from the engine's `ChromeDialogs`, which reads Chrome's views dialogs
through in-process accessibility, keeps their window invisible, and presses the chosen button; it can take a dialog
back (`DialogWithdrawal`) when Chrome closes it. Dialogs with fields, check boxes or web content keep Chrome's UI.

**Without it** — on Chromium a site's sign-in is cancelled (the engine always hands sign-ins to the browser
rather than Chrome's prompt); JavaScript dialogs and extension prompts fall back to Chrome's.

**Commands** — `dialogs.accept` (arguments `text`, or `username` and `password`, or `button`: its index for the
engine's dialogs), `dialogs.cancel` (automation and the keyboard).

**Tests** — `./forkctl test dialogs`; end to end: `EngineConformanceTests.pageDialogsAreTheBrowsers`,
`ExtensionAPITests.extensionPromptsAreTheBrowsers`.
