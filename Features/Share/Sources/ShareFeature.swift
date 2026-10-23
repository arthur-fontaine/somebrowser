import BrowserCore

/// Entry point declared in feature.json. Keep it small: register commands, hooks and views here and
/// put behaviour in separate, testable types.
public final class ShareFeature: BrowserFeature {
    private let context: FeatureContext

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.commands.handle("share.hello") { [context] _ in
            context.notify("Hello from Share")
        }
    }
}
