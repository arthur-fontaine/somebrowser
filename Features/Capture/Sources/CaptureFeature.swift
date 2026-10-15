import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Capture (Arc, ⇧⌘2): the page freezes, you drag over the part you want (Return: all of it), and the image is on the
/// clipboard, with Save… in the toast.
public final class CaptureFeature: BrowserFeature {
    let context: FeatureContext
    let model = CaptureModel()
    /// Where captures go (tests use their own).
    var pasteboard = NSPasteboard.general

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        let hasPage = { [runtime = context.runtime] (inv: CommandInvocation) in inv.window.flatMap { runtime.selectedTab(in: $0)?.engineTab } != nil }
        context.commands.handle("capture.start", isEnabled: hasPage) { [weak self] inv in self?.start(in: inv.window, selecting: true) }
        context.commands.handle("capture.visible", isEnabled: hasPage) { [weak self] inv in self?.start(in: inv.window, selecting: false) }
        let model = self.model
        context.ui.contribute(.contentOverlay, id: "capture.overlay", order: 50) { [weak self] window in
            CaptureOverlay(model: model, window: window, finish: { self?.finish(in: window, selection: $0) },
                           cancel: { model.sessions[window.id] = nil })
        }
    }

    func start(in window: BrowserWindowState?, selecting: Bool) {
        guard let window, let page = context.runtime.selectedTab(in: window)?.engineTab else { return }
        page.snapshot(maxWidth: .greatestFiniteMagnitude) { [weak self] image in
            guard let self, let image else { return }
            if selecting {
                self.model.sessions[window.id] = image
            } else {
                self.deliver(image, in: window)
            }
        }
    }

    /// `selection` in the page's points; nil: the whole page.
    func finish(in window: BrowserWindowState, selection: CGRect?) {
        guard let image = model.sessions.removeValue(forKey: window.id) else { return }
        guard let selection else { return deliver(image, in: window) }
        if let cropped = CaptureGeometry.crop(image, to: selection) { deliver(cropped, in: window) }
    }

    func deliver(_ image: NSImage, in window: BrowserWindowState) {
        guard let png = CaptureGeometry.png(image) else { return }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let parent = context.shell?.nsWindow(for: window)
        context.notify("Capture copied", systemImage: "camera.viewfinder", window: window, actionTitle: "Save…") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Capture.png"
            panel.allowedContentTypes = [.png]
            let save = { (response: NSApplication.ModalResponse) in
                if response == .OK, let url = panel.url { try? png.write(to: url, options: .atomic) }
            }
            if let parent { panel.beginSheetModal(for: parent, completionHandler: save) } else { save(panel.runModal()) }
        }
    }
}

@Observable
final class CaptureModel {
    /// Window → the frozen page being captured.
    var sessions: [UUID: NSImage] = [:]
}

nonisolated enum CaptureGeometry {
    /// The selection (points, top-left origin) as pixels of an image `pixelSize` big shown at `pointSize`.
    static func pixelRect(_ selection: CGRect, pointSize: CGSize, pixelSize: CGSize) -> CGRect {
        guard pointSize.width > 0, pointSize.height > 0 else { return .zero }
        let sx = pixelSize.width / pointSize.width, sy = pixelSize.height / pointSize.height
        let bounds = CGRect(origin: .zero, size: pixelSize)
        return CGRect(x: selection.minX * sx, y: selection.minY * sy, width: selection.width * sx, height: selection.height * sy)
            .integral.intersection(bounds)
    }

    static func crop(_ image: NSImage, to selection: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rect = pixelRect(selection, pointSize: image.size, pixelSize: CGSize(width: cg.width, height: cg.height))
        guard !rect.isEmpty, let part = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: part, size: CGSize(width: selection.width, height: selection.height))
    }

    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
