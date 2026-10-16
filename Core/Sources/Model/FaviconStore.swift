import AppKit
import Observation

/// Site icons the engines have already loaded (through `hooks.fetch`, which Security Core logs), by site, kept on disk:
/// history, the start page and tabs that aren't loaded show them without anything contacting the site. A private page's
/// icon is never stored.
@Observable
public final class FaviconStore {
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var absent: Set<String> = []
    /// Bumped when an icon arrives, so views showing a placeholder pick it up.
    private var revision = 0

    init(directory: URL?) {
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public func image(for url: URL?) -> NSImage? {
        _ = revision
        guard let key = Self.key(url) else { return nil }
        if let image = images[key] { return image }
        guard let directory, !absent.contains(key) else { return nil }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(key + ".png")) else {
            absent.insert(key)
            return nil
        }
        images[key] = image
        return image
    }

    func store(_ image: NSImage, for url: URL) {
        guard let key = Self.key(url), images[key] !== image else { return }
        images[key] = image
        absent.remove(key)
        revision += 1
        guard let directory, let png = Self.png(image) else { return }
        let file = directory.appendingPathComponent(key + ".png")
        DispatchQueue.global(qos: .utility).async { try? png.write(to: file, options: .atomic) }
    }

    /// One icon per site: the host without `www.`; only web pages have one.
    static func key(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme), var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.replacingOccurrences(of: "/", with: "_")
    }

    /// 64 px, enough for a 32 pt tile on a Retina screen.
    private static func png(_ image: NSImage) -> Data? {
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
