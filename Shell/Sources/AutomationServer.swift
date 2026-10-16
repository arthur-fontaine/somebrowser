import AppKit
import BrowserCore
import Foundation

/// Line-delimited JSON over a Unix socket, enabled with `BROWSER_AUTOMATION_SOCKET=/path`.
/// End-to-end tests (any engine) and agents drive the real app through it:
///
///     {"op":"run","command":"tabs.new","args":{}}
///     {"op":"open","url":"https://example.com"}
///     {"op":"navigate","url":"https://example.com/next"}
///     {"op":"state"}
///     {"op":"eval","js":"document.title"}
///     {"op":"simulate","url":"https://a.example/","html":"<title>A</title>"}
///     {"op":"setting","key":"adblock.enabled","value":false}
///
/// Any request may add `"private": true` (or `false`) to act on the first private (or normal) window.
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
        // `"private": true/false` targets the first private/normal window, else the key window.
        let window = (req["private"] as? Bool).map { wanted in runtime.windows.first { $0.isPrivate == wanted } } ?? runtime.keyWindow
        switch req["op"] as? String {
        case "run":
            guard let id = req["command"] as? String else { return reply(["ok": false, "error": "missing command"]) }
            let args = (req["args"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            do {
                // Main-thread time of the command and of the layout/drawing it caused (perf budgets).
                let start = DispatchTime.now()
                try runtime.commands.run(id, window: window, arguments: args)
                let ran = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                // Drawn on the run loop's next turn, as AppKit draws after an event. Not through the main dispatch queue:
                // with Chromium 156, a main-queue block queued from inside another (as this request runs) waits ~16 ms
                // after a page window is shown, while the run loop, which delivers input and draws, is free (2026-10-16).
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    MainActor.assumeIsolated {
                        NSApp.windows.forEach { $0.displayIfNeeded() }
                        let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                        reply(["ok": true, "ms": ran, "msUntilDrawn": total])
                    }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            } catch { reply(["ok": false, "error": "\(error)"]) }
        case "open":
            guard let s = req["url"] as? String, let url = URL(string: s), let window else { return reply(["ok": false, "error": "bad url or no window"]) }
            let tab = runtime.openTab(url, in: window)
            reply(["ok": true, "tab": tab.id.uuidString])
        case "openExternal":
            // As if another app opened the link (Air Traffic Control, mini windows).
            guard let s = req["url"] as? String, let url = URL(string: s) else { return reply(["ok": false, "error": "bad url"]) }
            NSApp.delegate?.application?(NSApp, open: [url])
            reply(["ok": true])
        case "navigate":
            // Browser-initiated navigation of the selected tab (like typing in the address bar).
            guard let s = req["url"] as? String, let url = URL(string: s), let window, let tab = runtime.selectedTab(in: window) else {
                return reply(["ok": false, "error": "bad url or no tab"])
            }
            runtime.navigate(tab, to: url)
            reply(["ok": true])
        case "simulate":
            // Loads `url` in the selected tab, answered with `html` instead of the network (engine conformance).
            guard let s = req["url"] as? String, let url = URL(string: s), let html = req["html"] as? String, let window,
                  let tab = runtime.selectedTab(in: window).map({ runtime.live($0) }),
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])
            else { return reply(["ok": false, "error": "bad request or no tab"]) }
            tab.loadSimulated(url, response: response, body: Data(html.utf8))
            reply(["ok": true])
        case "documentStart":
            // Runs `js` at document start of main-frame pages whose URL starts with `prefix` (engine conformance).
            guard let js = req["js"] as? String, let prefix = req["prefix"] as? String else { return reply(["ok": false, "error": "missing js/prefix"]) }
            runtime.engine.hooks.addDocumentStartScript { $0.absoluteString.hasPrefix(prefix) ? js : nil }
            reply(["ok": true])
        case "key":
            // A key press, as if typed (keyboard routing tests): in the key window, or with `page: true` in the page's
            // window (the engine's child window over the content area), focused first.
            let shellWindow = window.flatMap { shell?.nsWindow(for: $0) }
            let pageWindow = shellWindow?.childWindows?.last { $0.identifier != ShellOverlay.windowIdentifier && $0.frame.width > 2 && $0.isVisible }
            if req["page"] as? Bool == true { window?.viewport?.focusContent() }
            guard let chars = req["key"] as? String, let target = req["page"] as? Bool == true ? pageWindow : NSApp.keyWindow else {
                return reply(["ok": false, "error": "missing key or no target window"])
            }
            var flags: NSEvent.ModifierFlags = []
            for m in req["modifiers"] as? [String] ?? [] {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: target.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(req["keyCode"] as? Int ?? 0))
                else { continue }
                if target.isKeyWindow { NSApp.sendEvent(event) } else { target.sendEvent(event) }
            }
            reply(["ok": true, "keyWindow": String(describing: type(of: target))])
        case "click":
            // A left click in the page at (x, y) from its top-left (mouse routing tests).
            // In the engine's page window if it has one, else in the browser window over its web view (WebKit pages).
            let shellWindow = window.flatMap { shell?.nsWindow(for: $0) }
            let pageWindow = shellWindow?.childWindows?.last(where: { $0.identifier != ShellOverlay.windowIdentifier && $0.frame.width > 2 && $0.isVisible })
            let webView = shellWindow?.contentView.flatMap { Self.firstView(named: "WKWebView", in: $0) }
            guard let page = pageWindow ?? (webView != nil ? shellWindow : nil) else { return reply(["ok": false, "error": "no page"]) }
            let x = req["x"] as? Double ?? 20, y = req["y"] as? Double ?? 20
            let point: NSPoint
            if pageWindow == nil, let webView {
                let frame = webView.convert(webView.bounds, to: nil)
                point = NSPoint(x: frame.minX + x, y: frame.maxY - y)
            } else {
                point = NSPoint(x: x, y: page.frame.height - y)
            }
            // Delivered to the view AppKit hit-tests there, as a key window would: a test app in the background has no key
            // window, and a first click in a window that isn't key only makes it key.
            guard let target = page.contentView?.superview?.hitTest(point) ?? page.contentView?.hitTest(point) else {
                return reply(["ok": false, "error": "no view there"])
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: page.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { continue }
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
            var chain: [String] = []
            var hit: NSView? = target
            while let view = hit, chain.count < 6 { chain.append(String(describing: type(of: view))); hit = view.superview }
            reply(["ok": true, "hit": chain])
        case "hit":
            // The browser window's child windows (front to back) under (x, y) of the content area, with the AppKit view
            // and the accessibility path there (mouse routing checks).
            guard let shellWindow = window.flatMap({ shell?.nsWindow(for: $0) }), let w = window else { return reply(["ok": false]) }
            let content = w.contentFrame
            let local = NSPoint(x: content.minX + (req["x"] as? Double ?? 20), y: content.minY + (req["y"] as? Double ?? 20))
            let screen = shellWindow.convertPoint(toScreen: NSPoint(x: local.x, y: (shellWindow.contentView?.bounds.height ?? 0) - local.y))
            var found: [[String: Any]] = []
            for child in (shellWindow.childWindows ?? []).reversed() where child.isVisible && child.frame.contains(screen) {
                let point = child.convertPoint(fromScreen: screen)
                var chain: [String] = []
                var hit = child.contentView?.superview?.hitTest(point) ?? child.contentView?.hitTest(point)
                while let view = hit, chain.count < 4 { chain.append(String(describing: type(of: view))); hit = view.superview }
                // The accessibility path names Chromium's views, which all live in one AppKit view.
                var ax: [String] = []
                var element = child.accessibilityHitTest(screen) as? NSObject
                while let e = element, ax.count < 12 {
                    let get = { (key: String) in (e.responds(to: NSSelectorFromString(key)) ? e.value(forKey: key) : nil).map { "\($0)" } ?? "" }
                    // Chromium's nodes carry their views class name as the DOM class list.
                    let classes = (e.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXDOMClassList")) as? [String])?.joined(separator: " ") ?? ""
                    ax.append("\(type(of: e)) \(get("accessibilityRole")) \(get("accessibilitySubrole")) '\(get("accessibilityLabel"))' "
                              + "'\(get("accessibilityTitle"))' \(get("accessibilityFrame")) [\(classes)]")
                    element = e.responds(to: NSSelectorFromString("accessibilityParent")) ? e.value(forKey: "accessibilityParent") as? NSObject : nil
                }
                found.append(["window": String(describing: type(of: child)), "overlay": child.identifier == ShellOverlay.windowIdentifier,
                              "ignoresMouse": child.ignoresMouseEvents, "hit": chain, "ax": ax])
            }
            reply(["ok": true, "windows": found])
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
            // With `site`, a per-site setting (site controls, Boosts…).
            if let site = req["site"] as? String { runtime.siteSettings.set(key, value, for: site) } else { runtime.settings.set(key, value) }
            reply(["ok": true])
        case "views":
            // View hierarchy of the key browser window: class, frame, hidden — for layout tests and debugging.
            // `number` dumps any app window instead (a page child window, say), frame view included.
            let numbered = (req["number"] as? Int).flatMap { n in NSApp.windows.first { $0.windowNumber == n } }
            guard let w = window, let ns = numbered ?? shell?.nsWindow(for: w),
                  let root = numbered != nil ? ns.contentView?.superview : ns.contentView else { return reply(["ok": false, "error": "no window"]) }
            func dump(_ v: NSView, _ depth: Int) -> [[String: Any]] {
                guard depth < 40 else { return [] }
                var out: [[String: Any]] = [["depth": depth, "class": String(describing: type(of: v)),
                                             "frame": NSStringFromRect(v.frame), "hidden": v.isHidden]]
                for sub in v.subviews { out += dump(sub, depth + 1) }
                return out
            }
            let key = NSApp.keyWindow
            // Every app window front to back, with its parent: page, overlay and engine bubble composition.
            let windows: [[String: Any]] = NSApp.orderedWindows.map { w in
                ["number": w.windowNumber, "class": String(describing: type(of: w)), "frame": NSStringFromRect(w.frame),
                 "parent": w.parent?.windowNumber ?? 0, "visible": w.isVisible, "level": w.level.rawValue, "alpha": w.alphaValue]
            }
            reply(["ok": true, "views": dump(root, 0), "children": ns.childWindows?.map { NSStringFromRect($0.frame) } ?? [],
                   "windows": windows, "keyWindow": key.map { "\(type(of: $0))#\($0.identifier?.rawValue ?? "")" } ?? NSNull()])
        case "quit":
            reply(["ok": true])
            NSApp.terminate(nil)
        default:
            reply(["ok": false, "error": "unknown op"])
        }
    }

    /// Installed extensions, with their badge on the key window's selected page (what its sidebar shows).
    private func extensionsState() -> [[String: Any]] {
        guard let engine = runtime.engine as? EngineExtensions else { return [] }
        let window = runtime.keyWindow ?? runtime.windows.first
        let page = window.flatMap { runtime.selectedTab(in: $0)?.engineTab }
        let badges = page.map { engine.actionBadges(in: $0) } ?? [:]
        return engine.installedExtensions.map {
            ["id": $0.id, "name": $0.name, "pinned": $0.isPinned, "badge": badges[$0.id] ?? ""]
        }
    }

    static func firstView(named name: String, in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == name, !view.isHiddenOrHasHiddenAncestor { return view }
        for sub in view.subviews { if let found = firstView(named: name, in: sub) { return found } }
        return nil
    }

    /// This process's physical footprint in bytes (Activity Monitor's "Memory"), renderers and GPU excluded.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
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
            "memory": ["footprint": Self.footprint()],
            "engine": runtime.engine.id,
            "features": runtime.activationOrder,
            "extensions": extensionsState(),
            "windows": runtime.windows.map { w in
                [
                    "id": w.id.uuidString,
                    "space": w.spaceID.uuidString,
                    "selected": w.selectedTabID?.uuidString ?? NSNull(),
                    "sidebarVisible": w.isSidebarVisible,
                    "private": w.isPrivate,
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
