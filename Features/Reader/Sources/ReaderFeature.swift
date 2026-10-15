import BrowserCore
import Foundation

/// ⌥⌘R shows the page's article alone (Mozilla Readability), in the page, over it; again (or Esc) closes it.
public final class ReaderFeature: BrowserFeature {
    private let context: FeatureContext

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        let runtime = context.runtime
        context.commands.handle("reader.toggle", isEnabled: { inv in
            inv.window.flatMap { runtime.selectedTab(in: $0)?.engineTab } != nil
        }) { [weak self] inv in
            guard let window = inv.window, let page = runtime.selectedTab(in: window)?.engineTab else { return }
            page.evaluateJavaScript(ReaderScripts.toggle) { result in
                struct Reply: Decodable { var open: Bool; var unavailable: Bool? }
                guard case .success(let value) = result, let json = value as? String,
                      let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)), reply.unavailable == true else { return }
                self?.context.notify("This page has no article to show in Reader", systemImage: "doc.plaintext", window: window)
            }
        }
    }
}
