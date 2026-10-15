import Darwin
import Foundation

/// Safari's lock on its bookmarks (`Safari::FileLocker`, macOS 27): a `lock` folder next to Bookmarks.plist, made with
/// mkdir so only one process gets it, holding `details.plist` that says who. Safari and its sync agent take it to write
/// the file; a lock whose process is gone, or that's old, was abandoned and is taken over, as Safari does.
nonisolated struct SafariFileLock: Sendable {
    var folder: URL
    var timeout: TimeInterval = 5
    var abandonedAfter: TimeInterval = 60

    var directory: URL { folder.appendingPathComponent("lock", isDirectory: true) }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body()
    }

    private func acquire() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while mkdir(directory.path, 0o755) != 0 {
            guard errno == EEXIST else { throw SafariStore.StoreError.noAccess }
            if isAbandoned() {
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            guard Date() < deadline else { throw SafariStore.StoreError.busy }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let details: [String: Any] = [
            "LockFileUsername": NSUserName(),
            "LockFileProcessName": ProcessInfo.processInfo.processName,
            "LockFileProcessID": Int(getpid()),
            "LockFileDate": Date(),
            "LockFileHostname": Self.hostname,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: details, format: .binary, options: 0)
        try? data.write(to: directory.appendingPathComponent("details.plist"))
    }

    private func isAbandoned() -> Bool {
        let file = directory.appendingPathComponent("details.plist")
        guard let data = try? Data(contentsOf: file),
              let details = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            // Taken a moment ago, details not written yet; or left half-made.
            let made = (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            return Date().timeIntervalSince(made) > abandonedAfter
        }
        if let date = details["LockFileDate"] as? Date, Date().timeIntervalSince(date) > abandonedAfter { return true }
        if details["LockFileHostname"] as? String == Self.hostname, let pid = details["LockFileProcessID"] as? Int {
            return kill(pid_t(pid), 0) != 0 && errno == ESRCH
        }
        return false
    }

    /// gethostname, not `ProcessInfo.hostName` (which can wait on the network).
    static let hostname: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }()
}
