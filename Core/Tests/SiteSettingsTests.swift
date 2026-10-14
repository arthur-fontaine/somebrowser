import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct SiteSettingsTests {
    @Test func normalizesSitesAndPersists() async throws {
        #expect(SiteSettingsStore.site(for: URL(string: "https://WWW.Example.com/a")) == "example.com")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("site-\(UUID()).json")
        let store = SiteSettingsStore(url: url)
        store.set("permissions.camera", .string("grant"), for: "example.com")
        store.set("sound.muted", .bool(true), for: "example.com")
        #expect(store.bool("sound.muted", for: "example.com") == true)
        #expect(store.sites(with: "permissions.camera").keys.sorted() == ["example.com"])
        try await Task.sleep(for: .milliseconds(700))
        let reloaded = SiteSettingsStore(url: url)
        #expect(reloaded.value("permissions.camera", for: "example.com") == .string("grant"))
        reloaded.set("sound.muted", nil, for: "example.com")
        reloaded.set("permissions.camera", nil, for: "example.com")
        #expect(reloaded.all(for: "example.com").isEmpty)
    }
}
