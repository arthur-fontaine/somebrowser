# Print

**Purpose** — ⌘P prints the page with the macOS print panel; its PDF menu saves, previews or shares a PDF (Arc,
Horse).

**How it works** — `EngineTab.printPage()`. Chromium runs with `--disable-print-preview`, so `Print()` opens the
system panel instead of Chrome's web print preview; WebKit runs `WKWebView.printOperation` as a sheet.

**Commands** — `print.page` (⌘P, File menu; disabled on the start page).

**Tests** — `./forkctl test print`.

**Remove it** — `./forkctl feature disable print`.
