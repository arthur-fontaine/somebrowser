# Tinycast architecture study (abue-ammar/tinycast @ 57e29b4)

Swift 6, SwiftUI + AppKit, zero deps, ~819 files, XcodeGen `project.yml` **but the generated
`.xcodeproj` is committed**. Folders are per feature (`Features/<X>/{Model,Service,UI,Settings}`)
but **wiring is central**:

- `App/AppCore.swift` — singleton composition root: ~60 stores + 34 lazy coordinators with
  hand-passed concrete deps; `start()` hand-orders boot and wires callbacks.
- Exhaustive central enums/switches: `CommandID`, `CommandCatalog`, `LauncherCoordinator.runCommand`,
  `SettingsTab`, `SettingsDetailView`, `SettingsSearchCatalog`, `AppSettings` (844 lines),
  `SettingsFileKey`/`Schema`, backup coverage, `PaletteMode`, `RootPaletteView`, `HotKeyAction`.
- Enable/disable is runtime-only; removing a feature means deleting cases everywhere.
- Branding scattered: ~152 `"Tinycast"` literals, URLs, three icon locations.

Adding one feature with one command/setting/pane/hotkey edits **~18–22 shared files** → constant
rebase conflicts for forks.

## Lessons for us

1. Never commit the generated project; generate from manifests.
2. Each feature ships a manifest; the registry is generated/discovered, never hand-listed.
3. Open, namespaced string IDs (`"pip.toggle"`) instead of central enums; keep safety with a
   generated/validated check (unique IDs, every setting has a default, every command an owner).
4. Per-feature settings with key prefixes; settings UI/search/backup built from manifests.
5. Features talk through capability protocols + typed event bus; optional deps resolve to nil.
6. Compile-time removal of a feature by deleting one line in a fork-owned file.
7. A fork overlay directory upstream never touches.
8. Branding in one file feeding Info.plist, generated Swift constants and icons; lint against
   stray product-name literals.
9. Tests and docs live in the feature folder.
10. Shell files contain no feature names.
