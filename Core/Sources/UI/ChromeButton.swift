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
