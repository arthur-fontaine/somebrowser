import Foundation
import Testing
@testable import forkctl

@Test func shortcutsNormalize() {
    #expect(Validator.normalizeShortcut("shift+cmd+t") == Validator.normalizeShortcut("cmd+shift+T"))
    #expect(Validator.normalizeShortcut("alt+cmd+n") == "opt+cmd+n")
    #expect(Validator.isValidShortcut("cmd+shift+["))
    #expect(!Validator.isValidShortcut("hyper+t"))
}

@Test func pascalCaseIds() {
    #expect(pascalCase("command-bar") == "CommandBar")
    #expect(pascalCase("pip") == "Pip")
}

@Test func forksPinTheirOwnCEFBuild() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("forkctl-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: root) }
    let upstream = root.appendingPathComponent("Engines/CEF/vendor.json"), fork = root.appendingPathComponent("Fork/Engines/CEF/vendor.json")
    try FileManager.default.createDirectory(at: upstream.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"version":"1","url":"https://upstream.example/cef.tar.bz2","sha1":"a"}"#.write(to: upstream, atomically: true, encoding: .utf8)
    #expect(try Vendor.cefPin(root: root).version == "1")
    try FileManager.default.createDirectory(at: fork.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"version":"1-ungoogled","url":"https://fork.example/cef.tar.bz2","sha1":"b"}"#.write(to: fork, atomically: true, encoding: .utf8)
    #expect(try Vendor.cefPin(root: root).url == "https://fork.example/cef.tar.bz2")
}
