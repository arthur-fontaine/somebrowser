# Share

**Purpose** — Safari's Share: send the page's address with AirDrop, Messages, Mail or any share extension.

**How it works** — a share button in the address field's end (the `address-bar.trailing` slot, left of extensions and
reload) opens the system's share menu under it; File › Share… opens it under the address field, or at the page's top
when the sidebar is hidden. Only web pages and files are shared (the button hides on blank and browser pages).

**Commands**
- `share.page` — Share…

**Tests** — `./forkctl test share`.

**Remove it** — `./forkctl feature disable share`.
