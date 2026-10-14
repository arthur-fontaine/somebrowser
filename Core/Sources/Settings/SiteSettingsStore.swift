import Foundation
import Observation

/// Per-website settings (permissions, muted, auto pop-out, ad blocking…), keyed by host.
/// Features own their keys (namespaced like `permissions.camera`); the store only persists them.
@Observable
public final class SiteSettingsStore {
    private var values: [String: [String: SettingValue]] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var saveScheduled = false

    /// `url` nil keeps values in memory (tests).
    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: SettingValue]].self, from: data) {
            values = decoded
        }
    }

    /// Normalized key for a URL or host: lowercase host without `www.`.
    public static func site(for url: URL?) -> String? {
        guard var host = url?.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public func value(_ key: String, for site: String) -> SettingValue? { values[site]?[key] }

    public func bool(_ key: String, for site: String) -> Bool? { value(key, for: site)?.boolValue }

    public func set(_ key: String, _ value: SettingValue?, for site: String) {
        var entry = values[site] ?? [:]
        entry[key] = value
        values[site] = entry.isEmpty ? nil : entry
        scheduleSave()
    }

    /// Every site with a value for `key`.
    public func sites(with key: String) -> [String: SettingValue] {
        values.compactMapValues { $0[key] }
    }

    public func all(for site: String) -> [String: SettingValue] { values[site] ?? [:] }

    public func removeAll(for site: String) {
        values[site] = nil
        scheduleSave()
    }

    private func scheduleSave() {
        guard let url, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            try? JSONEncoder().encode(self.values).write(to: url, options: .atomic)
        }
    }
}
