import SwiftUI

/// An address shown as the sidebar's field draws it: a glass capsule `Size.control` tall, a leading symbol in the rows'
/// icon column, the text middle-truncated on their title column, controls at its end. Only the look: what it does
/// (editing, site controls) belongs to whoever shows it.
public struct AddressCapsule<Leading: View, Trailing: View>: View {
    let text: String
    let placeholder: String
    let leading: Leading
    let trailing: Trailing

    public init(_ text: String, placeholder: String = "", @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.placeholder = placeholder
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Design.Grid.iconToText) {
            leading.frame(width: Design.Size.favicon, height: Design.Size.control)
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) { trailing }
        }
        .padding(.leading, Design.Grid.iconInset)
        .padding(.trailing, Design.AddressField.trailingInset)
        .frame(height: Design.Size.control)
        .glassControl(in: Capsule())
    }
}
