import SwiftUI

/// A round glass button of the chrome (the sidebar's footer): a symbol in a `Design.Size.control` circle.
public struct ChromeButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    public init(systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: Design.Size.control, height: Design.Size.control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassControl(in: Circle())
        .help(help)
    }
}

/// A control inside the address field's end: a 28 pt circle, washed under the pointer (the field is glass already).
public struct FieldButton<Label: View>: View {
    let help: String
    let action: () -> Void
    let label: Label
    @State private var hovering = false

    public init(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.help = help
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .frame(width: Design.AddressField.control, height: Design.AddressField.control)
                .background(Circle().fill(hovering ? Design.Fill.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A control sitting on a panel (Quick Look's and sheets' toolbar buttons): a filled shape at rest, darker under the
/// pointer, darker still pressed. A fill, never glass, so the panel stays the one layer of glass.
public struct PanelControlStyle<S: Shape>: ButtonStyle {
    let shape: S
    let quiet: Bool

    /// `quiet`: a glyph (×) in the secondary colour until the pointer comes; text stays primary, or it reads as disabled.
    public init(_ shape: S, quiet: Bool = false) {
        self.shape = shape
        self.quiet = quiet
    }

    public func makeBody(configuration: Configuration) -> some View {
        PanelControl(label: configuration.label, isPressed: configuration.isPressed, shape: shape, quiet: quiet)
    }

    struct PanelControl: View {
        let label: Configuration.Label
        let isPressed: Bool
        let shape: S
        let quiet: Bool
        @State private var hovering = false

        var body: some View {
            label
                .foregroundStyle(!quiet || hovering || isPressed ? .primary : .secondary)
                .background(shape.fill(isPressed ? Design.Fill.pressed : hovering ? Design.Fill.selection : Design.Fill.control))
                .contentShape(shape)
                .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        }
    }
}

/// A panel's close button: a 24 pt filled disc with a 12 pt ×, in a 28 pt hit area (Quick Look's, sheets').
public struct PanelCloseButton: View {
    let help: String
    let action: () -> Void

    public init(help: String = "Close", action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(PanelControlStyle(Circle(), quiet: true))
        .frame(width: Design.AddressField.control, height: Design.AddressField.control)
        .help(help)
        .accessibilityLabel(help)
    }
}
