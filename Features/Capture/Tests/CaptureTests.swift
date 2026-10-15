import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureCapture

@MainActor
struct CaptureTests {
    /// 200 × 100 points at 2×: red on the left half, blue on the right.
    func page() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSColor.blue.setFill(); NSRect(x: 200, y: 0, width: 200, height: 200).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.addRepresentation(rep)
        return image
    }

    func harness() throws -> (TestHarness, CaptureFeature, NSPasteboard) {
        let h = try TestHarness(features: [CaptureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(CaptureFeature.self))
        let board = NSPasteboard(name: .init("capture-test-\(UUID().uuidString)"))
        feature.pasteboard = board
        h.fakeTab(h.openTab("https://a.example")).snapshotImage = page()
        return (h, feature, board)
    }

    func copied(_ board: NSPasteboard) -> NSBitmapImageRep? { board.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)) }

    @Test func selectionsMapToPixels() {
        let rect = CaptureGeometry.pixelRect(CGRect(x: 10, y: 5, width: 50, height: 20), pointSize: CGSize(width: 200, height: 100),
                                             pixelSize: CGSize(width: 400, height: 200))
        #expect(rect == CGRect(x: 20, y: 10, width: 100, height: 40))
        let clamped = CaptureGeometry.pixelRect(CGRect(x: 150, y: 80, width: 100, height: 100), pointSize: CGSize(width: 200, height: 100),
                                                pixelSize: CGSize(width: 400, height: 200))
        #expect(clamped == CGRect(x: 300, y: 160, width: 100, height: 40))
    }

    @Test func capturesTheVisiblePage() throws {
        let (h, _, board) = try harness()
        try h.run("capture.visible")
        let rep = try #require(copied(board))
        #expect(rep.pixelsWide == 400 && rep.pixelsHigh == 200)
    }

    /// The right half, at screen resolution: blue only.
    @Test func capturesTheSelectedPart() throws {
        let (h, feature, board) = try harness()
        try h.run("capture.start")
        #expect(feature.model.sessions[h.window.id] != nil)
        feature.finish(in: h.window, selection: CGRect(x: 100, y: 0, width: 100, height: 100))
        #expect(feature.model.sessions[h.window.id] == nil)
        let rep = try #require(copied(board))
        #expect(rep.pixelsWide == 200 && rep.pixelsHigh == 200)
        let color = try #require(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.9 && color.redComponent < 0.1)
    }

    @Test func pagesThatCantBeCapturedCopyNothing() throws {
        let (h, _, board) = try harness()
        h.fakeTab(try #require(h.selectedTab)).snapshotImage = nil
        try h.run("capture.visible")
        #expect(board.data(forType: .png) == nil)
    }
}
