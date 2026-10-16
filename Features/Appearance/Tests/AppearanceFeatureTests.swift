import BrowserCore
import BrowserTesting
import Testing
@testable import FeatureAppearance

@MainActor
struct AppearanceFeatureTests {
    /// The window's surface comes from this feature; glass unless the user picks solid.
    @Test func drawsTheWindowSurface() throws {
        let h = try TestHarness(features: [AppearanceFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.ui.views(for: "background").count == 1)
        #expect(h.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.glass.rawValue)
    }

    /// Committed to Liquid Glass: how the glass is drawn and what's behind it can change, never a color.
    @Test func noColorToPick() throws {
        let h = try TestHarness(features: [AppearanceFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.manifests.flatMap(\.settings).map(\.key).sorted() == ["appearance.backdrop", SurfaceStyle.settingKey])
    }
}
