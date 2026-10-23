import AppKit
import Foundation

/// Folders macOS keeps from other apps (Chrome's, on macOS 27: reading them fails with "Operation not permitted",
/// without a prompt). Picking the folder in an open panel is consent macOS honors; a security-scoped bookmark keeps it
/// across launches.
@MainActor
final class FolderGrants {
    let directory: URL
    /// Shows the open panel on a folder, with a message; returns what the user picked.
    var choose: (URL, String) -> URL?
    private var opened: [String: URL] = [:]

    init(directory: URL, choose: ((URL, String) -> URL?)? = nil) {
        self.directory = directory
        self.choose = choose ?? Self.panel
    }

    /// Starts using every folder granted earlier.
    func restoreAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "grant" {
            let id = file.deletingPathExtension().lastPathComponent
            guard opened[id] == nil, let data = try? Data(contentsOf: file) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            _ = url.startAccessingSecurityScopedResource()  // for the process lifetime
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? fresh.write(to: file, options: .atomic)
            }
            opened[id] = url
        }
    }

    /// Asks for `folder`; true once it's granted. Picking another folder doesn't count.
    func request(_ folder: URL, id: String, message: String) -> Bool {
        guard let chosen = choose(folder, message), Self.same(chosen, folder) else { return false }
        if let data = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("\(id).grant"), options: .atomic)
        }
        _ = chosen.startAccessingSecurityScopedResource()
        opened[id] = chosen
        return true
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func panel(_ folder: URL, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
