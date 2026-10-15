import Foundation

/// Reads installed extensions from a Chromium profile directory (`Default/`, `Profile 1/`…): `Secure Preferences`
/// holds `extensions.settings` (manifest, path, state), `Preferences` holds `extensions.pinned_extensions`.
/// Used by the Chromium engine (its own profile) and by importers (other browsers' profiles).
nonisolated public enum ChromiumExtensions {
    /// Component and external-component installs (PDF viewer, …) are part of the browser, not the user's.
    public static let hiddenLocations: Set<Int> = [5, 10]

    public static func read(profile: URL, locale: String = Locale.preferredLanguages.first ?? "en") -> [BrowserExtension] {
        let settings = (json(profile.appendingPathComponent("Secure Preferences"))?["extensions"] as? [String: Any])?["settings"] as? [String: Any]
            ?? (json(profile.appendingPathComponent("Preferences"))?["extensions"] as? [String: Any])?["settings"] as? [String: Any]
            ?? [:]
        let pinned = ((json(profile.appendingPathComponent("Preferences"))?["extensions"] as? [String: Any])?["pinned_extensions"] as? [String]) ?? []
        var out: [BrowserExtension] = []
        for (id, value) in settings {
            guard let entry = value as? [String: Any], !hiddenLocations.contains(entry["location"] as? Int ?? 0),
                  isEnabled(entry), let rawPath = entry["path"] as? String else { continue }
            let root = rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath)
                : profile.appendingPathComponent("Extensions").appendingPathComponent(rawPath)
            // Unpacked and command-line extensions keep no manifest copy: Chrome reads it from their folder.
            guard let manifest = entry["manifest"] as? [String: Any] ?? json(root.appendingPathComponent("manifest.json")) else { continue }
            let name = localized(manifest["name"] as? String ?? id, root: root, manifest: manifest, locale: locale)
            var ext = BrowserExtension(id: id, name: name, icon: icon(manifest, root: root), isPinned: pinned.contains(id))
            ext.isFromWebStore = entry["from_webstore"] as? Bool ?? false
            ext.sidePanelPath = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String
            ext.opensSidePanelOnClick = entry["open_side_panel_on_icon_click"] as? Bool ?? false
            ext.newTabPagePath = (manifest["chrome_url_overrides"] as? [String: Any])?["newtab"] as? String
            out.append(ext)
        }
        return out.sorted { a, b in
            switch (pinned.firstIndex(of: a.id), pinned.firstIndex(of: b.id)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Current Chrome: `disable_reasons` is a list (empty = enabled). Older profiles: `state` 1 = enabled.
    static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? [Any] { return reasons.isEmpty }
        if let reasons = entry["disable_reasons"] as? Int { return reasons == 0 }
        if let state = entry["state"] as? Int { return state == 1 }
        return true
    }

    /// Resolves `__MSG_key__` from `_locales/<locale>/messages.json`, falling back to the manifest's default locale.
    static func localized(_ value: String, root: URL, manifest: [String: Any], locale: String) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        let wanted = locale.replacingOccurrences(of: "-", with: "_")
        let candidates = [wanted, String(wanted.prefix(while: { $0 != "_" })), manifest["default_locale"] as? String].compactMap { $0 }
        for candidate in candidates {
            guard let messages = json(root.appendingPathComponent("_locales/\(candidate)/messages.json")) else { continue }
            for (k, v) in messages where k.lowercased() == key {
                if let message = (v as? [String: Any])?["message"] as? String { return message }
            }
        }
        return value
    }

    /// The toolbar icon (action icon, else the extension icon) closest to 32 px.
    static func icon(_ manifest: [String: Any], root: URL) -> URL? {
        let action = (manifest["action"] ?? manifest["browser_action"] ?? manifest["page_action"]) as? [String: Any]
        if let path = action?["default_icon"] as? String { return root.appendingPathComponent(path) }
        let sets = [action?["default_icon"] as? [String: String], manifest["icons"] as? [String: String]].compactMap { $0 }
        guard let set = sets.first(where: { !$0.isEmpty }) else { return nil }
        let best = set.min { abs((Int($0.key) ?? 0) - 32) < abs((Int($1.key) ?? 0) - 32) }
        return best.map { root.appendingPathComponent($0.value) }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
