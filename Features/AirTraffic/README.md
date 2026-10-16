# Air Traffic Control

**Purpose** — Arc's Air Traffic Control: links you open from other apps (Mail, Slack, Calendar…) go where your rules
say — a mini window, or the main window even when mini windows take links from other apps. Tools › Air Traffic
Control… edits the rules; the first match wins; no match keeps the usual behavior.

**How it works** — rules are a pattern (a host, which includes its subdomains, or the start of an address such as
`docs.google.com/document`) and a destination, stored in the feature's data folder. The feature registers the first
`BrowserRuntime.externalURLHandlers` entry, so it decides before mini windows. A mini-window rule runs `mini-window.new` with the link (by command id,
when that feature is present).

**Commands** — `air-traffic.edit`.

**Tests** — `./forkctl test air-traffic` (matching, main- and mini-window routing, persistence, old Space rules).

**Remove it** — `./forkctl feature disable air-traffic`.
