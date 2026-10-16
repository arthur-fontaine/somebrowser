import AppKit
import BrowserCore
import SwiftUI

/// The browser's own surfaces: the window around the page shows the desktop through the system's sidebar material,
/// and panels and bars are Liquid Glass (`glassSurface`); or all solid. Pages stay opaque content. The system's
/// Liquid Glass setting and Reduce Transparency still apply.
public final class AppearanceFeature: BrowserFeature {
    private let context: FeatureContext

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.ui.contribute("background", id: "appearance.window") { _ in WindowSurface() }
    }
}

/// Around the page: the desktop through the window (the system's sidebar material, which macOS draws as its own
/// sidebar glass), or solid.
struct WindowSurface: View {
    @Environment(BrowserEnvironment.self) private var env

    var body: some View {
        if env.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.solid.rawValue {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        } else {
            BehindWindow(material: .sidebar).ignoresSafeArea()
        }
    }
}

/// The desktop behind the window, blurred by the window server (glass inside the window has nothing to sample there).
struct BehindWindow: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
