import Foundation

enum Shell {
    struct Failure: Error, CustomStringConvertible {
        var command: [String]
        var status: Int32
        var description: String { "`\(command.joined(separator: " "))` exited with \(status)" }
    }

    /// Runs a process inheriting stdio (or silenced with `quiet`).
    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil, env: [String: String] = [:], quiet: Bool = false) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        if quiet {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(command: args, status: p.terminationStatus) }
        return p.terminationStatus
    }

    static func capture(_ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(command: args, status: p.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }
}
