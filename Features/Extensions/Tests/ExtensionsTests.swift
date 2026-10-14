import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureExtensions

@MainActor
struct ExtensionsTests {
    let ublock = BrowserExtension(id: "ublock", name: "uBlock Origin Lite", isPinned: true)
    let notes = BrowserExtension(id: "notes", name: "Notes")

    @Test func followsInstalledExtensions() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let model = try #require(h.runtime.feature(ExtensionsFeature.self)?.model)
        #expect(model.extensions.isEmpty)
        h.engine.simulateExtensions([ublock, notes])
        #expect(model.extensions.map(\.id) == ["ublock", "notes"])
        #expect(model.pinned.map(\.id) == ["ublock"])
    }

    @Test func iconsAreDecodedOncePerChange() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let model = try #require(h.runtime.feature(ExtensionsFeature.self)?.model)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("ext-icon-\(UUID().uuidString.prefix(6)).png")
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        h.engine.simulateExtensions([BrowserExtension(id: "a", name: "A", icon: png, isPinned: true), notes])
        let first = try #require(model.icons["a"])
        #expect(model.icons["notes"] == nil)
        h.engine.simulateExtensions([BrowserExtension(id: "a", name: "A renamed", icon: png, isPinned: true)])
        #expect(model.icons["a"] === first)
    }

    @Test func runsActionsOnTheSelectedPage() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        h.engine.simulateExtensions([ublock])
        _ = h.openTab("https://a.example")
        let selected = h.openTab("https://b.example")
        try h.run("extensions.run", arguments: ["id": "ublock"])
        #expect(h.engine.ranActions.map(\.id) == ["ublock"])
        #expect(h.engine.ranActions.first?.tab === h.fakeTab(selected))
    }

    @Test func menuOpensOnTheSelectedPage() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let tab = h.openTab("https://a.example")
        try h.run("extensions.menu")
        #expect(h.engine.extensionMenus.count == 1)
        #expect(h.engine.extensionMenus.first === h.fakeTab(tab))
    }

    /// Without an action host (e.g. `chromeToolbar: none`) the menu falls back to the management page.
    @Test func menuFallsBackToManagementPage() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        h.engine.toolbarAvailable = false
        _ = h.openTab("https://a.example")
        try h.run("extensions.menu")
        #expect(h.selectedTab?.url?.absoluteString == "chrome://extensions/")
    }

    @Test func managementAndStoreOpenTabs() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        try h.run("extensions.store")
        #expect(h.selectedTab?.url == ExtensionsFeature.storeURL)
        try h.run("extensions.manage")
        #expect(h.selectedTab?.url == ExtensionsFeature.manageURL)
    }
}
