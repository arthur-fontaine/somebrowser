import AppKit
import BrowserCore
import Foundation

/// Line-delimited JSON over a Unix socket, enabled with `BROWSER_AUTOMATION_SOCKET=/path`.
/// End-to-end tests (any engine) and agents drive the real app through it:
///
///     {"op":"run","command":"tabs.new","args":{}}
///     {"op":"open","url":"https://example.com"}
///     {"op":"state"}
///     {"op":"eval","js":"document.title"}
///     {"op":"setting","key":"adblock.enabled","value":false}
final class AutomationServer {
    let path: String
    private unowned let runtime: BrowserRuntime
    private weak var shell: ShellController?
    private var listenFD: Int32 = -1

    init(path: String, runtime: BrowserRuntime, shell: ShellController) {
        self.path = path
        self.runtime = runtime
        self.shell = shell
    }

    func start() {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) } }
        guard ok == 0, listen(listenFD, 4) == 0 else { return }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread { self?.serve(client) }
            }
        }
    }

    nonisolated private func serve(_ fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let response = respond(to: Data(line))
                handle.write(response + Data([0x0A]))
            }
        }
    }

    nonisolated private func respond(to line: Data) -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return Self.encode(["ok": false, "error": "invalid JSON"])
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [String: Any] = [:]
        DispatchQueue.main.async {
            self.handle(request) { r in
                result = r
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + 30) == .timedOut { return Self.encode(["ok": false, "error": "timeout"]) }
        return Self.encode(result)
    }

    nonisolated static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
    }

    private func handle(_ req: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let window = runtime.keyWindow
        switch req["op"] as? String {
        case "run":
            guard let id = req["command"] as? String else { return reply(["ok": false, "error": "missing command"]) }
            let args = (req["args"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            do {
                try runtime.commands.run(id, window: window, arguments: args)
                reply(["ok": true])
            } catch { reply(["ok": false, "error": "\(error)"]) }
        case "open":
            guard let s = req["url"] as? String, let url = URL(string: s), let window else { return reply(["ok": false, "error": "bad url or no window"]) }
            let tab = runtime.openTab(url, in: window)
            reply(["ok": true, "tab": tab.id.uuidString])
        case "state":
            reply(["ok": true, "state": stateJSON()])
        case "eval":
            guard let js = req["js"] as? String, let window, let tab = runtime.selectedTab(in: window)?.engineTab else {
                return reply(["ok": false, "error": "no live tab"])
            }
            tab.evaluateJavaScript(js) { r in
                switch r {
                case .success(let v): reply(["ok": true, "value": v.map { "\($0)" } ?? NSNull()])
                case .failure(let e): reply(["ok": false, "error": "\(e)"])
                }
            }
        case "setting":
            guard let key = req["key"] as? String, let raw = req["value"] else { return reply(["ok": false, "error": "missing key/value"]) }
            let value: SettingValue = switch raw {
            case let b as Bool: .bool(b)
            case let i as Int: .int(i)
            case let d as Double: .double(d)
            default: .string("\(raw)")
            }
            runtime.settings.set(key, value)
            reply(["ok": true])
        case "views":
            // View hierarchy of the key browser window: class, frame, hidden — for layout tests and debugging.
            guard let w = window, let ns = shell?.nsWindow(for: w), let root = ns.contentView else { return reply(["ok": false, "error": "no window"]) }
            func dump(_ v: NSView, _ depth: Int) -> [[String: Any]] {
                guard depth < 40 else { return [] }
                var out: [[String: Any]] = [["depth": depth, "class": String(describing: type(of: v)),
                                             "frame": NSStringFromRect(v.frame), "hidden": v.isHidden]]
                for sub in v.subviews { out += dump(sub, depth + 1) }
                return out
            }
            reply(["ok": true, "views": dump(root, 0), "children": ns.childWindows?.map { NSStringFromRect($0.frame) } ?? []])
        case "quit":
            reply(["ok": true])
            NSApp.terminate(nil)
        default:
            reply(["ok": false, "error": "unknown op"])
        }
    }

    private func stateJSON() -> [String: Any] {
        func tabJSON(_ id: NodeID) -> [String: Any]? {
            guard let t = runtime.tabs.tab(id) else { return nil }
            return [
                "id": t.id.uuidString,
                "url": (t.live?.url ?? t.url)?.absoluteString ?? "",
                "title": t.live?.title ?? t.title,
                "loaded": t.isLoaded,
                "loading": t.live?.isLoading ?? false,
                "children": runtime.tabs.children(of: id).compactMap(tabJSON),
            ]
        }
        return [
            "engine": runtime.engine.id,
            "features": runtime.activationOrder,
            "windows": runtime.windows.map { w in
                [
                    "id": w.id.uuidString,
                    "space": w.spaceID.uuidString,
                    "selected": w.selectedTabID?.uuidString ?? NSNull(),
                    "sidebarVisible": w.isSidebarVisible,
                    "flags": Array(w.flags).sorted(),
                ] as [String: Any]
            },
            "favorites": runtime.tabs.favorites.compactMap(tabJSON),
            "spaces": runtime.tabs.spaces.map { s in
                [
                    "id": s.id.uuidString, "name": s.name,
                    "pinned": s.pinned.compactMap(tabJSON), "today": s.today.compactMap(tabJSON),
                ] as [String: Any]
            },
        ]
    }
}
