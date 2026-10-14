import Foundation

public struct SessionSnapshot: Codable, Sendable {
    public struct WindowRecord: Codable, Sendable {
        public var id: UUID
        public var spaceID: UUID
        public var selectedTabID: NodeID?
        public var frame: String?
        public var isSidebarVisible: Bool
        public var sidebarWidth: Double
    }

    public var version = 1
    public var tabs: TabStore.Snapshot
    public var windows: [WindowRecord]
}

/// Debounced, atomic JSON persistence of the session (tabs, spaces, windows).
final class SessionPersistence {
    let url: URL
    private var pending: DispatchWorkItem?
    private let delay: TimeInterval

    init(url: URL, delay: TimeInterval = 1.0) {
        self.url = url
        self.delay = delay
    }

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
            return nil
        }
    }

    func scheduleSave(_ snapshot: @escaping () -> SessionSnapshot?) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            if let s = snapshot() { self?.saveNow(s) }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func saveNow(_ snapshot: SessionSnapshot) {
        pending?.cancel()
        pending = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
