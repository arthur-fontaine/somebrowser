import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureDownloads

@MainActor
struct DownloadsTests {
    @Test func lifecycleUpdatesModelAndNotifies() throws {
        let h = try TestHarness(features: [DownloadsFeature.self], manifestDirectory: #filePath)
        let model = try #require(h.runtime.feature(DownloadsFeature.self)?.model)
        let item = DownloadItem(sourceURL: URL(string: "https://a.example/file.zip"), suggestedFilename: "file.zip")
        item.totalBytes = 100
        h.engine.hooks.emit(.started(item))
        #expect(model.items.count == 1)
        #expect(model.flyToken == 1)
        item.receivedBytes = 50
        #expect(model.progress == 0.5)
        item.isFinished = true
        item.destination = URL(fileURLWithPath: "/tmp/file.zip")
        h.engine.hooks.emit(.finished(item))
        #expect(model.progress == nil)
        #expect(h.notifications.last == "Downloaded file.zip")
        try h.run("downloads.clear")
        #expect(model.items.isEmpty)
    }

    @Test func destinationsAreUniqueLikeFinder() {
        let dir = URL(fileURLWithPath: "/dl")
        let taken: Set<String> = ["/dl/report.pdf", "/dl/report 2.pdf", "/dl/noext"]
        let exists = { (u: URL) in taken.contains(u.path) }
        #expect(DownloadsModel.uniqueDestination(for: "report.pdf", in: dir, exists: exists).lastPathComponent == "report 3.pdf")
        #expect(DownloadsModel.uniqueDestination(for: "noext", in: dir, exists: exists).lastPathComponent == "noext 2")
        #expect(DownloadsModel.uniqueDestination(for: "a/b:c.txt", in: dir, exists: exists).lastPathComponent == "a-b-c.txt")
    }

    @Test func registersDestinationHook() throws {
        let h = try TestHarness(features: [DownloadsFeature.self], manifestDirectory: #filePath)
        let dest = h.engine.hooks.downloadDestination?(nil, "x.bin")
        #expect(dest?.lastPathComponent.hasPrefix("x") == true)
    }

    @Test func flightPathEndsAtTarget() {
        let end = FlyingDownload.arc(from: .zero, to: CGPoint(x: 100, y: 50), t: 1)
        #expect(end == CGPoint(x: 100, y: 50))
    }
}
