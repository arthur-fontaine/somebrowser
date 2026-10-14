# ADR-0001 — Architecture advice from Fable (2026-10-14)

Status: accepted as the starting point; spikes may amend it (see later ADRs).
Inputs: `docs/research/*.md`.

## 1. Engine strategy

- Ship **CEF Chrome style with inverted ownership** first (CEF owns the `NSWindow`; our SwiftUI
  views are overlaid inside it; the web view is inset). It is the only prebuilt-CEF mode on macOS
  with real Chrome extensions.
- Keep **CEF Alloy** (our own NSViews) and **WebKit** as second and third engines behind the same
  boundary.
- **Mixed Chrome+Alloy windows are rejected**: extensions only see tabs in Chrome's TabStripModel.
- **Source build (ungoogled patches, lift macOS `parent_view` restriction, H.264/AAC)** is the
  funded mid-term track, on remote CI.
- Never animate the web view's frame; only overlays animate. Inset changes land once at the end.

### Engine boundary (designed for the *weakest* engine shape)

```
protocol Engine { id, capabilities, bootstrap(config), makeWindowHost(options), makeTab(in:request:), hooks }
protocol WindowHost { nsWindow, overlayView, viewport, setContentInsets(_:) }   // shell never calls NSWindow()
protocol Viewport { present(_ tab), presented }   // Alloy/WebKit swap views; Chrome style activates in TabStripModel
protocol EngineTab { state (@Observable), load, back/forward/reload/stop, find, zoom, executeScript,
                     snapshot, devtools, discard, events: AsyncStream<TabEvent> }
struct EngineCapabilities { supportsExtensions, supportsPerTabViews, supportsNativePiP,
                            supportsContentRuleLists, supportsChromeURLs, maxViewportsPerWindow,
                            requestInterception }
struct EngineHooks { onBeforeRequest, popupPolicy, onContextCreated, permissionBroker,
                     downloadDelegate, userAgentBrand }
```

| Concern | Lives in |
|---|---|
| Ad-block decision | engine hook `onBeforeRequest`; AdBlock feature owns adblock-rust, lists, allowlist, creator policy |
| Cosmetic filters, scriptlets | feature via `onContextCreated` |
| Sign in with Apple | feature via `popupPolicy` (intercepts appleid.apple.com/auth/authorize) |
| Passwords autofill/save | feature (injected field observer + native popover + Apple Passwords) |
| Permissions | engine `permissionBroker`; Permissions feature = native UI + per-site store ("Security Core") |
| Downloads | engine `downloadDelegate`; Downloads feature = toast + fly animation |
| Find, zoom, devtools, snapshot | `EngineTab` |
| PiP | engine capability + PiP feature (floating panel, fling physics) |
| Tab tree, spaces, archive | engine-agnostic Core model; children parented from `popupRequested(opener)` |
| Extension toolbar/popups | feature gated on `supportsExtensions` |

## 2. Fork-friendly modules

```
Package.swift, project.yml   GENERATED, gitignored
Core/        Engine + Feature protocols, registry runtime, EventBus, settings, commands, Branding
Shell/       app delegate, window controller, sidebar/command-bar frames, keyboard router — no feature names
Engines/<Id>/  one target each (CEFChrome, CEFAlloy, WebKit, shared CEFCommon)
Features/<Name>/  feature.yml + Sources/ + Tests/ + README.md; imports Core only
Native/adblock-ffi/  Rust staticlib
Defaults/    brand.yml, features enabled set, default engine, icon
Fork/        never exists upstream; forks own it (fork.yml, Assets, Features)
Tools/forkctl/  generator + verbs
```

- `feature.yml` is the static source of truth (id, provides/requires/optional capabilities,
  lazy activation events, commands + default shortcuts + `when`, settings with defaults,
  contributions: sidebar/toolbar/panels/settings pane, URL schemes, engine hooks, `replaces`).
- Generator scans `Features/*/feature.yml` and `Fork/Features/*/feature.yml`, merges
  `Defaults/` ← `Fork/fork.yml`, emits `Package.swift`, `project.yml`, `FeatureRegistry.swift`,
  per-feature typed manifests and `Branding.swift`. Disabled features are not compiled.
- Features never import each other: capability protocols resolved by id (nil if absent) + typed
  EventBus.
- `forkctl sync` = merge upstream + regenerate + validate. Brand literals linted.

## 3. Agent-friendliness

- Short `AGENTS.md` with a task → recipe table (rename, icon, add/remove feature, swap engine,
  add shortcut/setting), a "never edit" list, and pointers to `forkctl`.
- Per-feature README template (purpose, invariants, capabilities, events, settings, tests, removal).
- `forkctl`: init, rename, icon, feature add/remove/disable, engine use, generate, validate, sync, doctor.
- `validate`: unique ids, handlers, defaults, shortcut collisions, capability graph, brand literals,
  no cross-feature imports, `Fork/` path rules.
- Golden tests: engine conformance suite, fork smoke job, sidebar snapshots at 1/50/500 tabs,
  manifest schema tests. ADRs in `docs/decisions/`.

## 4. Performance

- Paint the window from restored state before initializing CEF.
- Tab discarding policy (never audible/pinned/dirty forms); budgets: <150 MB app process,
  <20 MB model for 500 tabs, <400 ms to interactive before engine init.
- Lazy feature activation; one `@Observable` per tab; flat precomputed row list in `LazyVStack`;
  a single tracking area computes hover against *target* layout (Radian's instant hitbox).
- SwiftUI springs for list changes, `matchedGeometryEffect` for fly-to animations, Core Animation
  for interactive space swipe and toolbar auto-hide. Signposts + perf regression tests.

## 5. Spikes (ordered)

1. Chrome-style window with inverted ownership + SwiftUI sidebar + an MV3 extension working.
2. Driving tabs in the hidden TabStripModel (arbitrary activation <16 ms; opener tracking).
3. Three-engine golden test with one shell.
4. Overlays over web content, fullscreen, PiP.
5. adblock-rust bridge (<1 ms p99 per request).

Known risks: no H.264/AAC in prebuilt CEF; Chrome Web Store install unverified.

**Not risks — mandatory features (user decision, 2026-10-14):** Apple Passwords (autofill, save,
generation) and two-way Safari sync. Radian ships both, so they are proven possible; the work is
engineering (Passwords helper protocol client, Safari data formats + write-back), not a go/no-go
question. See `docs/research/apple-integrations.md` for the implementation routes.
