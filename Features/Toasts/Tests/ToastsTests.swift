import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureToasts

@MainActor
struct ToastsTests {
    @Test func showsScopedToastsAndExpires() async throws {
        let h = try TestHarness(features: [ToastsFeature.self], manifestDirectory: #filePath, settingOverrides: ["toasts.duration": .double(0.5)])
        let model = try #require(h.runtime.feature(ToastsFeature.self)?.model)
        h.context.notify("Hello")
        h.context.notify("Elsewhere", window: BrowserWindowState(spaceID: UUID()))
        #expect(model.visible(in: h.window).map(\.request.message) == ["Hello"])
        for i in 0..<5 { h.context.notify("n\(i)") }
        #expect(model.toasts.count == ToastModel.maxVisible)
        try await Task.sleep(for: .milliseconds(900))
        #expect(model.toasts.isEmpty)
    }
}
