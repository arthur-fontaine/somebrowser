# Reader

**Purpose** — ⌥⌘R (View › Reader) shows the page's article alone, in comfortable type: New York text, system
headings, light and dark themes, text size buttons. ⌥⌘R again, Esc or ✕ closes it (Horse; Safari's Reader).

**How it works** — the page runs Mozilla Readability 0.6.0 (Apache-2.0, vendored unchanged in
`ReadabilitySource.swift`) on a copy of the document, then the view is built over the page with DOM calls only (no
HTML strings: pages enforcing Trusted Types work) in a shadow root styled by a constructed stylesheet (not restricted
by page CSP). Event handler attributes and `javascript:` links are dropped from the article. Nothing runs until you
ask for it. Pages without an article show a toast instead.

**Commands** — `reader.toggle` (⌥⌘R, disabled on the start page).

**Tests** — `./forkctl test reader`; E2E on both engines (`readerShowsTheArticle`), including a strict-CSP page.

**Remove it** — `./forkctl feature disable reader`.
