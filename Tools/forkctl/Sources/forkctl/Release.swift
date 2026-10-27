import Foundation

/// Publishing: a GitHub release of this repository carrying our CEF build, then the pin pointing at it. The pin is
/// written only once the archive is uploaded, so it never names something that isn't there. App releases carry the
/// app as a DMG, which the Homebrew cask in `Casks/` installs.
enum Release {
    /// `owner/repo` of a GitHub remote URL (`git@github.com:o/r.git`, `https://github.com/o/r`), nil otherwise.
    static func githubRepo(_ remote: String) -> String? {
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let range = r.range(of: "github.com:") { path = r[range.upperBound...] }
        else if let range = r.range(of: "github.com/") { path = r[range.upperBound...] }
        else { return nil }
        let parts = path.split(separator: "/").map { $0.hasSuffix(".git") ? String($0.dropLast(4)) : String($0) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// The asset's download URL; CEF names carry `+`, which must be encoded.
    static func assetURL(repo: String, tag: String, name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("+")
        return "https://github.com/\(repo)/releases/download/\(tag)/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    /// `cef_binary_<version>_macosarm64_minimal.tar.bz2` → `<version>-somebrowser`.
    static func cefVersion(archiveName: String) -> String? {
        guard archiveName.hasPrefix("cef_binary_"), let end = archiveName.range(of: "_macos") else { return nil }
        return String(archiveName[archiveName.index(archiveName.startIndex, offsetBy: 11)..<end.lowerBound]) + "-somebrowser"
    }

    /// Uploads `archive` to release `tag` (created if needed) of the `origin` GitHub repository with `gh`, then pins it
    /// in `Engines/CEF/vendor.json` (or the fork's, with `fork`).
    static func publish(root: URL, tag: String, archive: URL, fork: Bool) throws {
        guard FileManager.default.fileExists(atPath: archive.path) else { throw ProjectError.invalid("no such archive: \(archive.path)") }
        guard let version = cefVersion(archiveName: archive.lastPathComponent) else {
            throw ProjectError.invalid("not a CEF minimal distribution archive: \(archive.lastPathComponent)")
        }
        let remote = (try? Shell.capture(["git", "remote", "get-url", "origin"], cwd: root)) ?? ""
        guard let repo = githubRepo(remote) else {
            throw ProjectError.invalid("no GitHub remote named origin: create the repository and add it first")
        }
        let sha1 = try Shell.capture(["shasum", "-a", "1", archive.path]).split(separator: " ").first.map(String.init) ?? ""
        if (try? Shell.run(["gh", "release", "view", tag, "--repo", repo], cwd: root, quiet: true)) == nil {
            // Not latest: the cask downloads the app from the latest release.
            try Shell.run(["gh", "release", "create", tag, "--repo", repo, "--title", tag, "--latest=false",
                           "--notes", "Chromium (CEF \(version)) built from source with the patches in Engines/CEF/patches."], cwd: root)
        }
        try Shell.run(["gh", "release", "upload", tag, archive.path, "--repo", repo, "--clobber"], cwd: root)
        let pin = Vendor.Pin(version: version, url: assetURL(repo: repo, tag: tag, name: archive.lastPathComponent), sha1: sha1)
        let file = root.appendingPathComponent(fork ? "Fork/Engines/CEF/vendor.json" : "Engines/CEF/vendor.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try (encoder.encode(pin) + Data("\n".utf8)).write(to: file)
        print("released \(archive.lastPathComponent) as \(repo)@\(tag); pinned in \(file.path.replacingOccurrences(of: root.path + "/", with: ""))")
    }

    /// The DMG's name, the same in every app release, so `releases/latest/download/<name>` always reaches the newest.
    static func dmgName(brandName: String) -> String { brandName.filter { !$0.isWhitespace } + ".dmg" }

    /// Packages `app` as a DMG and publishes it as release `tag` of the `origin` GitHub repository, marked latest.
    static func publishApp(root: URL, tag: String, app: URL, brandName: String) throws {
        let remote = (try? Shell.capture(["git", "remote", "get-url", "origin"], cwd: root)) ?? ""
        guard let repo = githubRepo(remote) else {
            throw ProjectError.invalid("no GitHub remote named origin: create the repository and add it first")
        }
        if (try? Shell.run(["gh", "release", "view", tag, "--repo", repo], cwd: root, quiet: true)) != nil {
            throw ProjectError.invalid("\(tag) is already released: bump VERSION")
        }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("forkctl-dmg-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try Shell.run(["cp", "-c", "-R", app.path, stage.path], quiet: true)
        try fm.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = app.deletingLastPathComponent().appendingPathComponent(dmgName(brandName: brandName))
        try Shell.run(["hdiutil", "create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO",
                       "-volname", brandName, "-srcfolder", stage.path, dmg.path])
        try Shell.run(["gh", "release", "create", tag, dmg.path, "--repo", repo, "--target", "main", "--latest",
                       "--title", "\(brandName) \(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)", "--generate-notes"], cwd: root)
        print("released \(dmg.lastPathComponent) as \(repo)@\(tag)")
    }
}
