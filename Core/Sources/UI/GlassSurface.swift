import SwiftUI

/// How the browser draws its own surfaces (setting `appearance.glass`): Liquid Glass, or solid for those who
/// find glass hard to read.
public enum SurfaceStyle: String, Sendable {
    case glass, solid

    public static let settingKey = "appearance.glass"
}

public extension View {
    /// The surface of the browser's own floating chrome (the window around the page, panels, bars, toasts): regular
    /// Liquid Glass, or with the solid style an opaque surface. Not for content (pages, lists inside a panel).
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }
}

struct GlassSurface<S: Shape>: ViewModifier {
    @Environment(BrowserEnvironment.self) private var env: BrowserEnvironment?
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        let solid = env?.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.solid.rawValue
        if solid {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}
