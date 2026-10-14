import AppKit
import BrowserCore
import SwiftUI

/// Native Sign in with Apple (Radian, 07-28): "Continue with Apple" on a site dims and blurs the page and shows the
/// system's Sign in with Apple sheet (Touch ID) in the window, then the site receives Apple's answer as if from
/// appleid.apple.com. When the system declines (no entitlement, unsupported request), the web flow continues.
public final class SignInWithAppleFeature: BrowserFeature {
    let context: FeatureContext
    let provider: AppleSignInProvider
    let model = AppleSignInModel()
    /// Authorize URLs the web flow may load (the system declined them, or we load Apple's answer).
    private var passthrough: Set<URL> = []
    private var session: AppleSignInSession?

    public convenience init(context: FeatureContext) {
        self.init(context: context, provider: AppSSOProvider())
    }

    init(context: FeatureContext, provider: AppleSignInProvider) {
        self.context = context
        self.provider = provider
    }

    public func activate() {
        context.hooks.addNavigationPolicy { [weak self] action in self?.policy(for: action) ?? .allow }
        let model = self.model
        context.ui.contribute(.contentOverlay, id: "apple-signin.backdrop", order: 80) { window in AppleSignInBackdrop(model: model, window: window) }
        context.ui.contribute(.overlay, id: "apple-signin.sheet", order: 96) { [weak self] window in
            AppleSignInSheet(model: model, window: window, cancel: { self?.session?.cancel() })
        }
    }

    static func isAuthorize(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "appleid.apple.com" && url.path() == "/auth/authorize"
    }

    func policy(for action: NavigationAction) -> NavigationPolicy {
        guard context.settings.bool("apple-signin.native"), action.isMainFrame, Self.isAuthorize(action.url), let tab = action.sourceTab else { return .allow }
        if passthrough.remove(action.url) != nil { return .allow }
        guard session == nil, provider.canHandle(action.url) else { return .allow }
        start(action.url, in: tab, userInitiated: action.userGesture)
        return .handled
    }

    func start(_ url: URL, in tab: EngineTab, userInitiated: Bool) {
        let origin = tab.state.url.flatMap { u in u.host().map { "\(u.scheme ?? "https")://\($0)" } }
        model.phase = .signingIn
        model.tab = ObjectIdentifier(tab)
        session = provider.begin(url, initiatorOrigin: origin, userInitiated: userInitiated) { [weak self, weak tab] event in
            guard let self, let tab else { return }
            self.handle(event, url: url, tab: tab)
        }
    }

    func handle(_ event: AppleSignInEvent, url: URL, tab: EngineTab) {
        switch event {
        case .present(let controller):
            model.sheet = controller
            model.phase = .sheet
        case .response(let response, let body):
            finish(success: true)
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: url)?.absoluteURL {
                tab.load(target)
            } else {
                passthrough.insert(url)
                tab.loadSimulated(url, response: response, body: body)
            }
        case .notHandled, .failed:
            finish(success: false)
            passthrough.insert(url)
            tab.load(url)
        case .cancelled:
            finish(success: false)
        }
    }

    private func finish(success: Bool) {
        session = nil
        model.sheet = nil
        model.phase = success ? .done : .idle
        if success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [model] in if model.phase == .done { model.phase = .idle } }
        }
    }
}

@Observable
final class AppleSignInModel {
    enum Phase: Equatable { case idle, signingIn, sheet, done }
    var phase: Phase = .idle
    var sheet: NSViewController?
    var tab: ObjectIdentifier?
}
