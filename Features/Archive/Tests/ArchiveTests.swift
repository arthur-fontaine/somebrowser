import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureArchive

@MainActor
struct ArchiveTests {
    func harness() throws -> (TestHarness, ArchiveFeature) {
        let h = try TestHarness(features: [ArchiveFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.feature(ArchiveFeature.self)))
    }

    @Test func idleBranchesAreArchivedButVisibleAndAudibleOnesStay() throws {
        let (h, feature) = try harness()
        let old = Date().addingTimeInterval(-13 * 3600)
        let idle = h.openTab("https://idle.example")
        let child = h.fakeTab(idle).simulateOpen(URL(string: "https://idle-child.example")!, disposition: .backgroundTab)
        _ = child
        let music = h.openTab("https://music.example")
        h.fakeTab(music).simulateMedia(audio: true, video: false)
        let current = h.openTab("https://current.example")
        for t in h.runtime.tabs.allTabs { t.lastActiveAt = old }
        let n = feature.archiveIdleTabs(now: Date())
        #expect(n == 2)
        #expect(h.runtime.tabs.tab(idle.id) == nil)
        #expect(h.runtime.tabs.tab(music.id) != nil)
        #expect(h.runtime.tabs.tab(current.id) != nil)
        #expect(feature.store.items.count == 2)
    }

    @Test func recentTabsAndNeverSettingAreRespected() throws {
        let (h, feature) = try harness()
        h.openTab("https://fresh.example")
        h.openTab("https://other.example")
        #expect(feature.archiveIdleTabs(now: Date()) == 0)
        h.runtime.settings.set("archive.after", .string("never"))
        for t in h.runtime.tabs.allTabs { t.lastActiveAt = .distantPast }
        #expect(feature.archiveIdleTabs(now: Date()) == 0)
    }

    @Test func restoreAndOmnibox() throws {
        let (h, feature) = try harness()
        let a = h.openTab("https://kittens.example")
        h.fakeTab(a).simulateTitle("Kittens")
        h.openTab("https://b.example")
        a.lastActiveAt = .distantPast
        feature.archiveIdleTabs(now: Date())
        let item = try #require(feature.store.items.first)
        #expect(item.title == "Kittens")
        let results = h.runtime.capabilities.all(OmniboxProvider.self).flatMap { $0.items(for: "kitt", in: h.window) }
        #expect(results.first?.kind == "Archived")
        feature.restore(item, in: h.window)
        #expect(h.selectedTab?.url?.host() == "kittens.example")
        #expect(feature.store.items.isEmpty)
    }

    @Test func pruneOldArchives() throws {
        let (_, feature) = try harness()
        feature.store.add([ArchivedTab(tab: BrowserTab(url: URL(string: "https://x.example")!), spaceID: UUID(), at: .distantPast)])
        feature.store.prune(keepDays: 30, now: Date())
        #expect(feature.store.items.isEmpty)
    }
}
