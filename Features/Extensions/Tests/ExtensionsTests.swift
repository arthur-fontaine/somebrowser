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

    var panel: BrowserExtension {
        var ext = BrowserExtension(id: "panel", name: "Panel")
        ext.sidePanelPath = "/side.html"
        ext.opensSidePanelOnClick = true
        return ext
    }

    /// Chrome would draw the panel in its own window chrome: the extension's button opens it beside the content instead.
    @Test func sidePanelsOpenFromTheButtonBesideTheContent() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let panels = try #require(h.runtime.feature(ExtensionsFeature.self)?.sidePanels.model)
        h.engine.simulateExtensions([panel, ublock])
        _ = h.openTab("https://a.example")
        try h.run("extensions.run", arguments: ["id": "panel"])
        let page = try #require(panels.panels[h.window.id]?.page as? FakeEngineTab)
        #expect(page.state.url?.absoluteString == "chrome-extension://panel/side.html")
        #expect(h.engine.ranActions.isEmpty)
        #expect(h.runtime.tabs.allTabs.count == 1)
        try h.run("extensions.run", arguments: ["id": "panel"])
        #expect(panels.panels[h.window.id] == nil)
        #expect(page.isClosed)
        try h.run("extensions.run", arguments: ["id": "ublock"])
        #expect(h.engine.ranActions.map(\.id) == ["ublock"])
    }

    @Test func sidePanelCommandOpensPanelsWhoseButtonDoesSomethingElse() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let panels = try #require(h.runtime.feature(ExtensionsFeature.self)?.sidePanels.model)
        var other = panel
        other.opensSidePanelOnClick = false
        h.engine.simulateExtensions([other])
        _ = h.openTab("https://a.example")
        try h.run("extensions.run", arguments: ["id": "panel"])
        #expect(h.engine.ranActions.map(\.id) == ["panel"])
        #expect(panels.panels[h.window.id] == nil)
        try h.run("extensions.side-panel")
        #expect(panels.panels[h.window.id]?.extensionID == "panel")
    }

    /// Links the panel opens become tabs of its window; `window.close()` closes the panel.
    @Test func panelLinksBecomeTabs() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let panels = try #require(h.runtime.feature(ExtensionsFeature.self)?.sidePanels.model)
        h.engine.simulateExtensions([panel])
        _ = h.openTab("https://a.example")
        try h.run("extensions.side-panel", arguments: ["id": "panel"])
        let page = try #require(panels.panels[h.window.id]?.page as? FakeEngineTab)
        page.simulateOpen(URL(string: "https://docs.example")!)
        #expect(h.selectedTab?.url?.absoluteString == "https://docs.example")
        #expect(h.runtime.tabs.allTabs.count == 2)
        page.delegate?.engineTabDidRequestClose(page)
        #expect(panels.panels[h.window.id] == nil)
    }

    @Test func providesAnExtensionsNewTabPage() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        let provider = try #require(h.runtime.capabilities.newTabPage)
        h.engine.simulateExtensions([ublock])
        #expect(provider.newTabPage(in: h.window) == nil)
        var tab = notes
        tab.newTabPagePath = "tab.html"
        h.engine.simulateExtensions([ublock, tab])
        #expect(provider.newTabPage(in: h.window)?.absoluteString == "chrome-extension://notes/tab.html")
        h.runtime.settings.set("extensions.newTabPage", .bool(false))
        #expect(provider.newTabPage(in: h.window) == nil)
    }

    @Test func managementAndStoreOpenTabs() throws {
        let h = try TestHarness(features: [ExtensionsFeature.self], manifestDirectory: #filePath)
        try h.run("extensions.store")
        #expect(h.selectedTab?.url == ExtensionsFeature.storeURL)
        try h.run("extensions.manage")
        #expect(h.selectedTab?.url == ExtensionsFeature.manageURL)
    }
}
