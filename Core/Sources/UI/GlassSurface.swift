import SwiftUI

/// How the browser draws its own surfaces (setting `appearance.glass`): Liquid Glass, regular (frosted, the system's
/// default) or clear (more see-through, for colorful backdrops), or solid for those who find glass hard to read.
public enum SurfaceStyle: String, Sendable {
    case glass, clear, solid

    public static let settingKey = "appearance.glass"
}

public extension View {
    /// The surface of the browser's own floating chrome (panels, bars, toasts): Liquid Glass, or with the solid style an
    /// opaque surface. Not for content (pages, lists inside a panel).
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive, tint: nil))
    }

    /// A control of the browser's own (a button, a group of buttons, the address field, the selected tab): interactive
    /// Liquid Glass, which lights up, bounces and lenses under the pointer as the system's controls do. `tint` only when
    /// the color means something (Apple's guidance: never for decoration).
    func glassControl<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, interactive: true, tint: tint))
    }
}

/// Glass shapes near each other blend and morph as one (the system's `GlassEffectContainer`): a group of buttons, the
/// sidebar's controls. Glass can't sample other glass, so related glass shares one container.
public struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}

struct GlassSurface<S: Shape>: ViewModifier {
    @Environment(BrowserEnvironment.self) private var env: BrowserEnvironment?
    let shape: S
    let interactive: Bool
    let tint: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        let style = env.flatMap { SurfaceStyle(rawValue: $0.runtime.settings.string(SurfaceStyle.settingKey)) } ?? .glass
        if style == .solid {
            // Interactive glass lights up under the pointer; a solid control gets the hover wash instead.
            content
                .background {
                    ZStack {
                        shape.fill(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                        shape.fill(interactive && hovering ? Design.Fill.hover : .clear)
                    }
                }
                .onHover { h in if interactive { withAnimation(Design.Motion.hover) { hovering = h } } }
        } else {
            content.glassEffect(glass(style), in: shape)
        }
    }

    private func glass(_ style: SurfaceStyle) -> Glass {
        var glass: Glass = style == .clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}
