import BrowserCore

/// ⌘P: the engine shows the system print panel for the page (its PDF menu saves or shares a PDF).
public final class PrintFeature: BrowserFeature {
    private let context: FeatureContext

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        let runtime = context.runtime
        context.commands.handle("print.page", isEnabled: { inv in
            inv.window.flatMap { runtime.selectedTab(in: $0)?.engineTab } != nil
        }) { inv in
            inv.window.flatMap { runtime.selectedTab(in: $0)?.engineTab }?.printPage()
        }
    }
}
