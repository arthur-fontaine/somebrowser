import Foundation

let usage = """
forkctl — build, test and customize this browser (and your fork of it).

Usage: ./forkctl <command> [options]

Everyday
  generate                 Regenerate Package.swift, registry and branding from manifests
  validate                 Check manifests, ids, shortcuts, capabilities, imports, brand literals
  build [--release]        generate + validate + compile + assemble build/<Name>.app
  run [--release]          build, then launch the app (logs in this terminal)
  test [feature…] [--e2e]  Run unit/integration tests (all, or only the given feature ids);
                           --e2e builds the app and runs the end-to-end engine suite against it
  doctor                   Check toolchain, vendored engines, project health

Customize a fork (writes only Fork/, never upstream files)
  rename <Name> [--bundle-id id] [--scheme s]
  icon <path/to/1024.png>
  engine list | engine use <id>
  feature list | feature enable <id> | feature disable <id>
  feature new <id> [--fork]   Scaffold a feature (code, manifest, README, tests)
  shortcut <command-id> <keys|none>
  setting <key> <json-value>

Engines
  vendor cef               Download + verify the pinned CEF build and its C++ wrapper
"""

struct CLI {
    var root: URL
    var args: [String]

    func project() throws -> Project { try ProjectLoader.load(root: root) }

    func flag(_ name: String) -> Bool { args.contains(name) }
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    var positional: [String] {
        var out: [String] = []
        var skip = false
        for (i, a) in args.enumerated() where i > 0 {
            if skip { skip = false; continue }
            if a.hasPrefix("--") { skip = ["--bundle-id", "--scheme"].contains(a); continue }
            out.append(a)
        }
        return out
    }

    func runCommand() throws {
        switch args.first {
        case "generate":
            let p = try project()
            try Generator.run(p)
            print("generated for \(p.brand.name) · engine \(p.engine.id) · \(p.enabled.count) features")
        case "validate":
            try validate(try project(), failOnWarning: flag("--strict"))
            print("ok")
        case "build":
            _ = try build(release: flag("--release"))
        case "run":
            let app = try build(release: flag("--release"))
            let exe = app.appendingPathComponent("Contents/MacOS/\(try project().brand.executableName)")
            try Shell.run([exe.path] + Array(args.drop(while: { $0 != "--" }).dropFirst()))
        case "test":
            try test(features: positional)
        case "doctor":
            try doctor()
        case "rename":
            guard let name = positional.first else { throw ProjectError.invalid("usage: forkctl rename <Name>") }
            try ForkFile.update(root) { f in
                var b = f.brand ?? BrandConfig()
                b.name = name
                let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
                b.bundleId = option("--bundle-id") ?? b.bundleId ?? "dev.\(slug).\(slug)"
                b.urlScheme = option("--scheme") ?? slug
                b.userAgentBrand = name
                f.brand = b
            }
            try regenerate("renamed to \(name)")
        case "icon":
            guard let src = positional.first else { throw ProjectError.invalid("usage: forkctl icon <png>") }
            let dest = root.appendingPathComponent("Fork/Assets/AppIcon.png")
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: dest)
            try ForkFile.update(root) { f in
                var b = f.brand ?? BrandConfig()
                b.icon = "Fork/Assets/AppIcon.png"
                f.brand = b
            }
            try regenerate("icon set")
        case "engine":
            let p = try project()
            if positional.first == "use", let id = positional.dropFirst().first {
                guard p.engines.contains(where: { $0.id == id }) else {
                    throw ProjectError.invalid("unknown engine '\(id)'; available: \(p.engines.map(\.id).sorted())")
                }
                try ForkFile.update(root) { $0.engine = id }
                try regenerate("engine → \(id)")
            } else {
                for e in p.engines { print("\(e.id == p.engine.id ? "*" : " ") \(e.id)\t\(e.name)") }
            }
        case "feature":
            try feature()
        case "shortcut":
            let pos = positional
            guard pos.count == 2 else { throw ProjectError.invalid("usage: forkctl shortcut <command-id> <keys|none>") }
            try ForkFile.update(root) { f in
                var s = f.shortcuts ?? [:]
                s[pos[0]] = pos[1] == "none" ? "" : pos[1]
                f.shortcuts = s
            }
            try regenerate("shortcut \(pos[0]) → \(pos[1])")
        case "setting":
            let pos = positional
            guard pos.count == 2 else { throw ProjectError.invalid("usage: forkctl setting <key> <json-value>") }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(pos[1].utf8))
            try ForkFile.update(root) { f in
                var s = f.settings ?? [:]
                s[pos[0]] = value
                f.settings = s
            }
            try regenerate("setting \(pos[0]) → \(pos[1])")
        case "vendor":
            guard positional.first == "cef" else { throw ProjectError.invalid("usage: forkctl vendor cef") }
            try Vendor.cef(root: root)
        default:
            print(usage)
        }
    }

    func regenerate(_ message: String) throws {
        let p = try project()
        try Generator.run(p)
        print("\(message) (Fork/fork.json updated, project regenerated)")
    }

    func validate(_ p: Project, failOnWarning: Bool = false) throws {
        let issues = Validator.run(p)
        for i in issues { FileHandle.standardError.write(Data("\(i)\n".utf8)) }
        if issues.contains(where: { $0.level == .error }) || (failOnWarning && !issues.isEmpty) {
            throw ProjectError.invalid("validation failed (\(issues.count) issue(s))")
        }
    }

    func build(release: Bool) throws -> URL {
        var p = try project()
        if p.engine.vendor == "cef", !FileManager.default.fileExists(atPath: root.appendingPathComponent("Vendor/cef/Release").path) {
            try Vendor.cef(root: root)
            p = try project()
        }
        try Generator.run(p)
        try validate(p)
        let config = release ? "release" : "debug"
        try buildCrates(p)
        try Shell.run(["swift", "build", "-c", config, "--product", p.brand.executableName], cwd: root)
        if p.engine.bundler == "cef" {
            try Shell.run(["swift", "build", "-c", config, "--product", "BrowserHelper"], cwd: root)
        }
        let app = try Bundler.bundle(p, configuration: config)
        print("built \(app.path)")
        return app
    }

    /// Features' Rust crates, always optimized (they are dependencies, not code being debugged).
    func buildCrates(_ p: Project) throws {
        for f in p.enabled {
            guard let crate = f.manifest.cargo else { continue }
            let manifest = root.appendingPathComponent("\(f.directory)/\(crate)/Cargo.toml").path
            // --locked: dependencies are exactly the committed Cargo.lock (no silent drift).
            try Shell.run(["cargo", "build", "--release", "--quiet", "--locked", "--manifest-path", manifest], cwd: root)
        }
    }

    func test(features ids: [String]) throws {
        let p = try project()
        try Generator.run(p)
        try validate(p)
        var cmd = ["swift", "test"]
        var env: [String: String] = [:]
        if flag("--e2e") {
            // End-to-end: build the real app and drive it (tests/E2E) on the selected engine.
            let app = try build(release: flag("--release"))
            env["BROWSER_E2E_APP"] = app.appendingPathComponent("Contents/MacOS/\(p.brand.executableName)").path
            if ids.isEmpty { cmd += ["--filter", "BrowserE2ETests"] }
        }
        if !ids.isEmpty {
            let targets = ids.map { id -> String in
                if id == "core" { return "BrowserCoreTests" }
                if id == "shell" { return "BrowserShellTests" }
                if id == "engine" { return "\(p.engine.module)Tests" }
                return "Feature\(pascalCase(id))Tests"
            }
            cmd += ["--filter", targets.map { "^\($0)\\." }.joined(separator: "|")]
        }
        try buildCrates(p)
        try Shell.run(cmd, cwd: root, env: env)
    }

    func feature() throws {
        let p = try project()
        let pos = positional
        switch pos.first {
        case "enable", "disable":
            guard let id = pos.dropFirst().first else { throw ProjectError.invalid("usage: forkctl feature \(pos[0]) <id>") }
            guard p.features.contains(where: { $0.manifest.id == id }) else { throw ProjectError.invalid("unknown feature '\(id)'") }
            try ForkFile.update(root) { f in
                var sel = f.features ?? ForkConfig.FeatureSelection()
                var enable = Set(sel.enable ?? []), disable = Set(sel.disable ?? [])
                if pos[0] == "enable" { enable.insert(id); disable.remove(id) } else { disable.insert(id); enable.remove(id) }
                sel.enable = enable.isEmpty ? nil : enable.sorted()
                sel.disable = disable.isEmpty ? nil : disable.sorted()
                f.features = sel
            }
            try regenerate("feature \(id) \(pos[0])d")
        case "new":
            guard let id = pos.dropFirst().first else { throw ProjectError.invalid("usage: forkctl feature new <id> [--fork]") }
            let dir = try Scaffold.feature(id: id, root: root, fork: flag("--fork"))
            try Generator.run(try project())
            print("created \(dir.path.replacingOccurrences(of: root.path + "/", with: "")) — implement it, then `./forkctl test \(id)`")
        default:
            let enabled = Set(p.enabled.map(\.manifest.id))
            for f in p.features.sorted(by: { $0.manifest.id < $1.manifest.id }) {
                let mark = enabled.contains(f.manifest.id) ? "✓" : " "
                print("\(mark) \(f.manifest.id)\(f.isFork ? " (fork)" : "")\t\(f.manifest.summary)")
            }
        }
    }

    func doctor() throws {
        var ok = true
        func check(_ label: String, _ pass: Bool, _ hint: String = "") {
            print("\(pass ? "✓" : "✗") \(label)\(pass || hint.isEmpty ? "" : " — \(hint)")")
            if !pass { ok = false }
        }
        check("swift toolchain", (try? Shell.capture(["swift", "--version"])) != nil, "install Xcode 26+")
        let p = try project()
        print("  brand: \(p.brand.name) (\(p.brand.bundleId)) · engine: \(p.engine.id) · features: \(p.enabled.count)/\(p.features.count)")
        if p.engine.vendor == "cef" {
            check("CEF vendored", FileManager.default.fileExists(atPath: root.appendingPathComponent("Vendor/cef/Release").path), "run ./forkctl vendor cef")
        }
        let issues = Validator.run(p)
        check("manifests valid", !issues.contains { $0.level == .error }, "run ./forkctl validate")
        if !ok { throw ProjectError.invalid("doctor found problems") }
    }
}

/// `Fork/fork.json` is the only file the fork verbs write.
enum ForkFile {
    static func update(_ root: URL, _ change: (inout ForkConfig) -> Void) throws {
        let url = root.appendingPathComponent("Fork/fork.json")
        var config = (try? readJSON(ForkConfig.self, at: url)) ?? ForkConfig()
        change(&config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (enc.encode(config) + Data("\n".utf8)).write(to: url)
    }
}

// MARK: entry

var argv = Array(CommandLine.arguments.dropFirst())
var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
if let i = argv.firstIndex(of: "--root"), i + 1 < argv.count {
    root = URL(fileURLWithPath: argv[i + 1])
    argv.removeSubrange(i...(i + 1))
}
do {
    try CLI(root: root, args: argv).runCommand()
} catch {
    FileHandle.standardError.write(Data("forkctl: \(error)\n".utf8))
    exit(1)
}
