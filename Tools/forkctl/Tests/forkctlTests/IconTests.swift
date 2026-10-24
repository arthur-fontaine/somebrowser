import Foundation
import Testing
@testable import forkctl

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forkctl-icon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The default icon is an Icon Composer document: it compiles to the asset catalog (glass, dark, tinted) and an .icns.
@Test func compilesTheDefaultIcon() throws {
    let out = try scratch()
    defer { try? FileManager.default.removeItem(at: out) }
    try Bundler.compileIcon(root.appendingPathComponent("Defaults/Assets/AppIcon.icon"), into: out)
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Assets.car").path))
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("AppIcon.icns").path))
}

/// A document actool rejects (here: five groups, Icon Composer allows four) fails the build with actool's reason.
@Test func rejectsAnInvalidIcon() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = dir.appendingPathComponent("Broken.icon")
    try FileManager.default.createDirectory(at: doc.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    try #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><circle cx="512" cy="512" r="300"/></svg>"#
        .write(to: doc.appendingPathComponent("Assets/dot.svg"), atomically: true, encoding: .utf8)
    let group = #"{"layers":[{"image-name":"dot.svg","name":"dot"}]}"#
    try #"{"groups":[\#(Array(repeating: group, count: 5).joined(separator: ","))],"supported-platforms":{"squares":"shared"}}"#
        .write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    let out = dir.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let error = #expect(throws: ProjectError.self) { try Bundler.compileIcon(doc, into: out) }
    #expect(error?.description.contains("maximum group limit") == true)
}

@Test func namesTheCatalogIcon() throws {
    let data = try Bundler.infoPlist(ProjectLoader.load(root: root), principalClass: "NSApplication")
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["CFBundleIconName"] as? String == "AppIcon")
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
}
