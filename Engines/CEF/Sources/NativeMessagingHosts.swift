import Foundation

/// Apps that talk to their Chrome extension (Claude Code and Claude for "Claude in Chrome", 1Password…) install a
/// native messaging manifest for Chrome only, or for a fixed list of browsers this one isn't on. Chromium looks for
/// them in the profile's own NativeMessagingHosts folder (CEF's root cache path), so the user's Chrome manifests are
/// mirrored there at launch. They name the extensions allowed to connect; a host only runs when one of them asks.
enum NativeMessagingHosts {
    static let chromeFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)

    /// Copies each manifest of `source` into `destination` when missing or changed. Returns the copied names.
    @discardableResult
    static func mirror(from source: URL = chromeFolder, into destination: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return [] }
        var copied: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: source.appendingPathComponent(name)),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
            let target = destination.appendingPathComponent(name)
            if (try? Data(contentsOf: target)) == data { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            if (try? data.write(to: target, options: .atomic)) != nil { copied.append(name) }
        }
        return copied
    }
}
