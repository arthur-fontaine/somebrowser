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
