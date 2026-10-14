import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureAppleSignin

final class FakeProvider: AppleSignInProvider {
    var handles = true
    var begun: [(url: URL, origin: String?, userInitiated: Bool)] = []
    var events: ((AppleSignInEvent) -> Void)?
    var cancelled = false

    final class Session: AppleSignInSession {
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    func canHandle(_ url: URL) -> Bool { handles }
    func begin(_ url: URL, initiatorOrigin: String?, userInitiated: Bool, events: @escaping (AppleSignInEvent) -> Void) -> AppleSignInSession {
        begun.append((url, initiatorOrigin, userInitiated))
        self.events = events
        return Session { [weak self] in self?.cancelled = true; self?.events?(.cancelled) }
    }
}

@MainActor
struct SignInWithAppleTests {
    let authorize = URL(string: "https://appleid.apple.com/auth/authorize?client_id=com.site&redirect_uri=https%3A%2F%2Fsite.example%2Fcb&response_mode=form_post")!

    func setUp() throws -> (TestHarness, SignInWithAppleFeature, FakeProvider, FakeEngineTab) {
        let h = try TestHarness(features: [SignInWithAppleFeature.self], manifestDirectory: #filePath, activate: false)
        let provider = FakeProvider()
        let feature = SignInWithAppleFeature(context: h.context, provider: provider)
        feature.activate()
        let tab = h.fakeTab(h.openTab("https://site.example/login"))
        return (h, feature, provider, tab)
    }

    @Test func authorizeNavigationsGoNative() throws {
        let (h, feature, provider, tab) = try setUp()
        #expect(h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab, userGesture: true)) == .handled)
        #expect(provider.begun.first?.origin == "https://site.example")
        #expect(provider.begun.first?.userInitiated == true)
        #expect(feature.model.phase == .signingIn)
        provider.events?(.present(NSViewController()))
        #expect(feature.model.phase == .sheet && feature.model.sheet != nil)
        // Apple's form_post page is loaded with appleid.apple.com's origin, not intercepted again.
        let response = HTTPURLResponse(url: authorize, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        provider.events?(.response(response, Data("<form method=post action=https://site.example/cb>".utf8)))
        #expect(tab.simulatedLoads.map(\.url) == [authorize])
        #expect(feature.model.phase == .done && feature.model.sheet == nil)
        #expect(h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab)) == .allow)
    }

    @Test func redirectsAreFollowed() throws {
        let (h, feature, provider, tab) = try setUp()
        _ = h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab))
        let response = HTTPURLResponse(url: authorize, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://site.example/cb?code=abc"])!
        provider.events?(.response(response, Data()))
        #expect(tab.state.url?.absoluteString == "https://site.example/cb?code=abc")
        #expect(tab.simulatedLoads.isEmpty)
        #expect(feature.model.phase == .done)
    }

    /// Unentitled builds: the system declines and the regular web flow continues, once.
    @Test func declinedAttemptsFallBackToTheWeb() throws {
        let (h, feature, provider, tab) = try setUp()
        _ = h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab))
        provider.events?(.notHandled)
        #expect(tab.state.url == authorize)
        #expect(feature.model.phase == .idle)
        #expect(provider.begun.count == 1)
    }

    @Test func cancellingRestoresThePage() throws {
        let (h, feature, provider, tab) = try setUp()
        _ = h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab))
        provider.events?(.present(NSViewController()))
        provider.events?(.cancelled)
        #expect(feature.model.phase == .idle)
        #expect(tab.state.url?.host() == "site.example")
    }

    @Test func otherNavigationsAndDisabledSettingAreUntouched() throws {
        let (h, feature, provider, tab) = try setUp()
        defer { withExtendedLifetime(feature) {} }
        #expect(h.engine.hooks.decide(NavigationAction(url: URL(string: "https://appleid.apple.com/account")!, sourceTab: tab)) == .allow)
        #expect(h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab, isMainFrame: false)) == .allow)
        provider.handles = false
        #expect(h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab)) == .allow)
        provider.handles = true
        h.runtime.settings.set("apple-signin.native", false)
        #expect(h.engine.hooks.decide(NavigationAction(url: authorize, sourceTab: tab)) == .allow)
        #expect(provider.begun.isEmpty)
    }

    /// The real provider loads AppSSO and answers for Apple ID URLs on this system.
    @Test func appSSOIsAvailable() {
        #expect(AppSSOProvider.loaded)
        #expect(AppSSOProvider().canHandle(authorize))
        #expect(!AppSSOProvider().canHandle(URL(string: "https://site.example/")!))
    }
}
