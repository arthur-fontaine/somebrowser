import BrowserCore
import SwiftUI

/// The frozen page, dimmed except for the part being selected.
struct CaptureOverlay: View {
    let model: CaptureModel
    let window: BrowserWindowState
    let finish: (CGRect?) -> Void
    let cancel: () -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        if let image = model.sessions[window.id] {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable()
                Canvas { context, size in
                    var dim = Path(CGRect(origin: .zero, size: size))
                    if let selection { dim.addRect(selection) }
                    context.fill(dim, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                    if let selection {
                        context.stroke(Path(selection), with: .color(.white), lineWidth: 1.5)
                    }
                }
                if let selection, selection.width > 40 {
                    Text("\(Int(selection.width)) × \(Int(selection.height))")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                        .offset(x: selection.minX, y: max(selection.minY - 24, 4))
                }
                VStack {
                    Text("Drag to capture · Return for the whole page · Esc to cancel")
                        .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                // Return and Esc, while the overlay has the keyboard.
                Button("", action: { finish(nil) }).keyboardShortcut(.defaultAction).opacity(0)
                Button("", action: cancel).keyboardShortcut(.cancelAction).opacity(0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
                .onEnded { _ in
                    let rect = selection
                    start = nil
                    current = nil
                    if let rect, rect.width >= 4, rect.height >= 4 { finish(rect) }
                })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .overlayKeyboardFocus("capture", in: window)
        }
    }
}
