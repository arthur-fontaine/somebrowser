import AppKit
import BrowserCore
import SwiftUI

public final class ShareFeature: BrowserFeature {
    private let context: FeatureContext

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.commands.handle("share.page", isEnabled: { [weak self] inv in self?.url(in: inv.window) != nil }) { [weak self] inv in
            guard let self, let window = inv.window else { return }
            self.share(in: window, from: nil)
        }
        // Between the extensions and reload, so it stays put however many extensions show.
        context.ui.contribute("address-bar.trailing", id: "share.button", order: 250) { [weak self] window in
            if let self { ShareButton(window: window, feature: self) }
        }
    }

    /// Web pages and files: what a share extension can take (not the start page or a browser page).
    func url(in window: BrowserWindowState?) -> URL? {
        guard let window, let tab = context.runtime.selectedTab(in: window),
              let url = tab.live?.url ?? tab.url, ["http", "https", "file"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// The system's share menu under `anchor`, or under the address field (the page's top when it's hidden).
    func share(in window: BrowserWindowState, from anchor: NSView?) {
        guard let url = url(in: window) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let anchor, anchor.window != nil {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            return
        }
        guard let view = context.shell?.nsWindow(for: window)?.contentView else { return }
        // State frames are window coordinates from the top-left.
        let top = window.addressFieldFrame == .zero
            ? CGRect(x: window.contentFrame.midX, y: window.contentFrame.minY, width: 1, height: 1) : window.addressFieldFrame
        let rect = view.isFlipped ? top : CGRect(x: top.minX, y: view.bounds.height - top.maxY, width: top.width, height: top.height)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }
}

/// A 28 pt circle in the address field's end, beside reload.
struct ShareButton: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let feature: ShareFeature
    @State private var anchor = Anchor()

    var body: some View {
        // Read for observation: the button comes and goes with the page.
        let _ = env.runtime.selectedTab(in: window)?.live?.url
        if feature.url(in: window) != nil {
            FieldButton(help: "Share") { feature.share(in: window, from: anchor.view) } label: {
                // Reload's size; its arrow makes it taller, and its box sat low beside reload's circle.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .offset(y: -1)
                    .foregroundStyle(.secondary)
            }
            .background(AnchorView(anchor: anchor))
        }
    }
}

/// The button's own view, for the share menu to point at.
final class Anchor {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let anchor: Anchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
