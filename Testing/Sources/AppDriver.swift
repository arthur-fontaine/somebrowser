import Foundation
import Network

/// Launches the real bundled app with an isolated profile and drives it through the automation socket.
/// Used by end-to-end tests (`./forkctl test --e2e`) so every engine runs the same scenarios.
nonisolated public final class AppDriver: @unchecked Sendable {
    public let process = Process()
    public let directory: URL
    private let socketName = "a.sock"

    /// `executable`: `build/<Name>.app/Contents/MacOS/<Name>`.
    public init(executable: String, extraEnvironment: [String: String] = [:], arguments: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory  // keeps the socket path short
        var env = ProcessInfo.processInfo.environment
        env["BROWSER_DATA_DIR"] = directory.appendingPathComponent("data").path
        env["BROWSER_AUTOMATION_SOCKET"] = socketName
        env["BROWSER_FRESH_WINDOW"] = "1"
        env.merge(extraEnvironment) { $1 }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        do {
            try waitUntil(timeout: 30) { (try? self.call(["op": "state"]))?["ok"] as? Bool == true }
        } catch {
            throw DriverError.timeout("app did not answer within 30s of launch\n\(mainThreadSample())")
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    public enum DriverError: Error { case timeout(String), socket(String), badResponse, crashed(String) }

    /// One request/response over the socket.
    @discardableResult
    public func call(_ request: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DriverError.socket("socket") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = directory.appendingPathComponent(socketName).path
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw DriverError.socket("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { throw DriverError.socket("connect") }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let obj = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else { throw DriverError.badResponse }
        return obj
    }

    /// Runs a command; returns its main-thread time in ms, and the time until the windows were drawn.
    @discardableResult
    public func run(_ command: String, _ args: [String: String] = [:]) throws -> (ms: Double, drawn: Double) {
        let r = try call(["op": "run", "command": command, "args": args])
        if r["ok"] as? Bool != true { throw DriverError.socket("\(command): \(r["error"] ?? "?")") }
        return (r["ms"] as? Double ?? 0, r["msUntilDrawn"] as? Double ?? 0)
    }

    /// Types a key in the key window (`modifiers`: cmd, shift, opt, ctrl; `keyCode`: the virtual key code).
    public func key(_ key: String, modifiers: [String] = [], keyCode: Int, inPage: Bool = true) throws {
        try call(["op": "key", "key": key, "modifiers": modifiers, "keyCode": keyCode, "page": inPage])
    }

    /// The app process's physical footprint in bytes (renderers and GPU excluded).
    public func footprint() throws -> Int { ((try state()["memory"] as? [String: Any])?["footprint"] as? Int) ?? -1 }

    public func open(_ url: String) throws { try call(["op": "open", "url": url]) }

    /// Loads a URL in the selected tab, as if typed in the address bar.
    public func navigate(_ url: String) throws { try call(["op": "navigate", "url": url]) }

    /// Loads `url` in the selected tab answered with `html` (no network), with `url`'s origin.
    public func simulate(_ url: String, html: String) throws { try call(["op": "simulate", "url": url, "html": html]) }

    /// Registers `js` to run at document start of pages whose URL starts with `prefix`.
    public func documentStart(_ js: String, prefix: String) throws { try call(["op": "documentStart", "js": js, "prefix": prefix]) }

    public func eval(_ js: String) throws -> Any? { try call(["op": "eval", "js": js])["value"] }

    public func state() throws -> [String: Any] { (try call(["op": "state"]))["state"] as? [String: Any] ?? [:] }

    /// Flattened tabs of the first space: (title, url, depth).
    public func tabs() throws -> [(title: String, url: String, depth: Int)] {
        let s = try state()
        var out: [(String, String, Int)] = []
        func walk(_ t: [String: Any], _ d: Int) {
            out.append((t["title"] as? String ?? "", t["url"] as? String ?? "", d))
            for c in t["children"] as? [[String: Any]] ?? [] { walk(c, d + 1) }
        }
        for space in s["spaces"] as? [[String: Any]] ?? [] {
            for t in (space["pinned"] as? [[String: Any]] ?? []) + (space["today"] as? [[String: Any]] ?? []) { walk(t, 0) }
        }
        return out
    }

    public func waitUntil(timeout: TimeInterval, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? condition()) == true { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw DriverError.timeout("condition not met in \(timeout)s")
    }

    /// Quits through the app's normal termination path and waits for the process to exit. Chromium's shutdown alone
    /// took up to 9.9 s on a loaded Mac (2026-10-15): the bound is for hangs.
    public func quit(timeout: TimeInterval = 20) throws {
        _ = try? call(["op": "quit"])
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { throw DriverError.timeout("app did not exit in \(timeout)s\n\(mainThreadSample())") }
        // A crash during teardown is still a failure, even though the process is gone.
        if process.terminationReason == .uncaughtSignal || process.terminationStatus != 0 {
            throw DriverError.crashed("exit \(process.terminationStatus) (\(process.terminationReason == .uncaughtSignal ? "signal" : "status"))")
        }
    }

    /// Main-thread stack of the running app (via `sample`), so a hang is diagnosable from the test log.
    public func mainThreadSample() -> String {
        // `sample` writes its report to a file (stdout only gets the path).
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString.prefix(6)).txt")
        defer { try? FileManager.default.removeItem(at: report) }
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(process.processIdentifier), "1", "-file", report.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        guard (try? sampler.run()) != nil else { return "" }
        sampler.waitUntilExit()
        let output = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return "" }
        return lines[start..<min(start + 40, lines.count)].joined(separator: "\n")
    }

    public static var executableFromEnvironment: String? { ProcessInfo.processInfo.environment["BROWSER_E2E_APP"] }
}

/// Minimal HTTP/1.1 server for deterministic test pages (Network framework, no dependencies).
nonisolated public final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let pages: [String: String]
    public private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "test-http")

    public init(pages: [String: String]) throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    public func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = self.pages[path.components(separatedBy: "?")[0]]
            let status = body == nil ? "404 Not Found" : "200 OK"
            let payload = Data((body ?? "not found").utf8)
            var head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            if path == "/favicon.ico" { head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
            c.send(content: Data(head.utf8) + (path == "/favicon.ico" ? Data() : payload), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
