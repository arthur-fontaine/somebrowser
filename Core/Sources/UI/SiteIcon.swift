import AppKit
import SwiftUI

/// A site's icon as the chrome shows it: the image (or a symbol), slightly rounded. In Dark, an icon that is dark itself
/// (a black logo) sits on a light plate, or it would vanish into the sidebar. Size it with `.frame`.
public struct SiteIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: NSImage?
    let placeholder: String

    public init(_ image: NSImage?, placeholder: String = "globe") {
        self.image = image
        self.placeholder = placeholder
    }

    public var body: some View {
        if let image {
            let plate = colorScheme == .dark && IconTone.isDark(image)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.favicon, style: .continuous))
                .scaleEffect(plate ? 0.8 : 1)
                .background {
                    if plate {
                        RoundedRectangle(cornerRadius: Design.Radius.favicon + 1, style: .continuous).fill(.white.opacity(0.9)).padding(-1)
                    }
                }
        } else {
            Image(systemName: placeholder).resizable().scaledToFit().foregroundStyle(.tertiary)
        }
    }
}

/// Whether an icon is dark: its opaque pixels' mean luminance, measured once per image.
enum IconTone {
    private static let cache = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    static func isDark(_ image: NSImage) -> Bool {
        if let known = cache.object(forKey: image) { return known.boolValue }
        let dark = luminance(of: image).map { $0 < 0.3 } ?? false
        cache.setObject(NSNumber(value: dark), forKey: image)
        return dark
    }

    private static func luminance(of image: NSImage) -> Double? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.1 else { continue }
            // Premultiplied: divide the alpha back out.
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            sum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
            weight += a
        }
        return weight > 0 ? sum / weight : nil
    }
}
