# Security Core

**Purpose** — Radian's Security Core, "verify where your data goes": one place that shows what the browser contacts by
itself, and every permission sites were given.

**How it works** — Core's `OutboundConnections` makes every request of the browser's own code (features through
`context.fetch`, engines through `hooks.fetch`) and logs it: time, host, scheme + host + path (never the query string:
search suggestions carry what you type), purpose, the feature that asked, status, size. `forkctl validate` rejects
URLSession in features and engines, so nothing goes around it. These requests carry no cookies and keep none. Private
windows' requests use an ephemeral session and aren't logged. Favicons stay in memory; the rest (the last 500) is kept in
`<data>/Security/connections.json`. The Permissions tab shows the permission broker's log (`PermissionsService`).

**Not observed** — pages and extensions (their traffic is theirs), and Chromium's own requests: CEF doesn't expose them.
Those are update checks to the Chrome Web Store for extensions installed from it; with none installed, an idle browser
contacts nobody (E2E `idleProfileContactsNoThirdParty`, from Chromium's net log). The panel says so.

**Commands** — `security-core.show` — Security Core… (Tools menu, command bar).

**Capabilities** — optional `permissions`.

**Tests** — `./forkctl test security-core`; Core: `OutboundConnectionsTests`; forkctl: `ownRequestsMustGoThroughTheLog`.

**Remove it** — `./forkctl feature disable security-core` (requests are still logged by Core; only the panel goes).
