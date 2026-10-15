import Foundation

enum Scaffold {
    /// Creates a ready-to-build feature with manifest, README and a passing test, so an agent can start
    /// from a green state and see exactly where code goes.
    static func feature(id: String, root: URL, fork: Bool) throws -> URL {
        guard id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw ProjectError.invalid("feature id must be lowercase kebab-case (e.g. reading-list)")
        }
        let name = pascalCase(id)
        let dir = root.appendingPathComponent(fork ? "Fork/Features/\(name)" : "Features/\(name)")
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw ProjectError.invalid("\(dir.path) already exists") }
        let title = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let files: [String: String] = [
            "feature.json": """
            {
              "id": "\(id)",
              "name": "\(title)",
              "summary": "One line describing what \(title) does.",
              "entry": "\(name)Feature",
              "provides": [],
              "requires": [],
              "commands": [
                { "id": "\(id).hello", "title": "\(title): Hello", "menu": "View", "group": "\(id)" }
              ],
              "settings": [
                { "key": "\(id).enabled", "title": "Enable \(title)", "type": "bool", "default": true }
              ]
            }

            """,
            "README.md": """
            # \(title)

            **Purpose** — what the user gets.

            **How it works** — the main types and the hooks/capabilities it uses.

            **Capabilities** — provides: none · requires: none.

            **Commands & settings** — see `feature.json`.

            **Tests** — `./forkctl test \(id)`; what they prove.

            **Remove it** — `./forkctl feature disable \(id)`; nothing else depends on it.

            """,
            "Sources/\(name)Feature.swift": """
            import BrowserCore

            /// Entry point declared in feature.json. Keep it small: register commands, hooks and views here and
            /// put behaviour in separate, testable types.
            public final class \(name)Feature: BrowserFeature {
                private let context: FeatureContext

                public init(context: FeatureContext) {
                    self.context = context
                }

                public func activate() {
                    context.commands.handle("\(id).hello") { [context] _ in
                        context.notify("Hello from \(title)")
                    }
                }
            }

            """,
            "Tests/\(name)FeatureTests.swift": """
            import BrowserCore
            import BrowserTesting
            import Testing
            @testable import Feature\(name)

            @MainActor
            struct \(name)FeatureTests {
                @Test func helloCommandIsHandled() async throws {
                    let harness = try TestHarness(features: [\(name)Feature.self], manifestDirectory: #filePath)
                    #expect(harness.context.commands.canRun("\(id).hello"))
                    try harness.run("\(id).hello")
                    #expect(harness.notifications.last == "Hello from \(title)")
                }
            }

            """,
        ]
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }
}

enum Vendor {
    struct Pin: Codable {
        var version: String
        var url: String
        var sha1: String
    }

    /// The CEF build to use: a fork's own (`Fork/Engines/CEF/vendor.json`, e.g. an ungoogled source build, see
    /// docs/recipes/ungoogled-cef.md) or upstream's pin.
    static func cefPin(root: URL) throws -> Pin {
        let fork = root.appendingPathComponent("Fork/Engines/CEF/vendor.json")
        return try readJSON(Pin.self, at: FileManager.default.fileExists(atPath: fork.path) ? fork : root.appendingPathComponent("Engines/CEF/vendor.json"))
    }

    /// Downloads the pinned CEF minimal distribution into the user cache (shared across clones/forks),
    /// verifies it, builds `libcef_dll_wrapper` and links it as `Vendor/cef`.
    static func cef(root: URL) throws {
        let pin = try cefPin(root: root)
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/somebrowser-vendor/cef")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tarball = cache.appendingPathComponent(URL(string: pin.url)!.lastPathComponent.removingPercentEncoding!)
        let dir = cache.appendingPathComponent(tarball.lastPathComponent.replacingOccurrences(of: ".tar.bz2", with: ""))
        if !FileManager.default.fileExists(atPath: tarball.path) {
            print("downloading CEF \(pin.version)…")
            try Shell.run(["curl", "-fSL", "-o", tarball.path, pin.url])
        }
        let sha = try Shell.capture(["shasum", "-a", "1", tarball.path]).split(separator: " ").first.map(String.init)
        guard sha == pin.sha1 else { throw ProjectError.invalid("CEF checksum mismatch: \(sha ?? "?") ≠ \(pin.sha1)") }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try Shell.run(["tar", "xjf", tarball.path, "-C", cache.path])
        }
        let wrapper = dir.appendingPathComponent("build/libcef_dll_wrapper/libcef_dll_wrapper.a")
        if !FileManager.default.fileExists(atPath: wrapper.path) {
            let build = dir.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Shell.run(["cmake", "-G", "Unix Makefiles", "-DPROJECT_ARCH=arm64", "-DCMAKE_BUILD_TYPE=Release", ".."], cwd: build, quiet: true)
            try Shell.run(["make", "-j8", "libcef_dll_wrapper"], cwd: build, quiet: true)
        }
        let link = root.appendingPathComponent("Vendor/cef")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        print("CEF \(pin.version) ready at Vendor/cef")
    }
}
