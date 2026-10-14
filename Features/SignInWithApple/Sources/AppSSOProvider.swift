import AppKit
import Foundation
import ObjectiveC

/// What happens to a native Sign in with Apple attempt.
enum AppleSignInEvent {
    /// The system's sheet to show in the window.
    case present(NSViewController)
    /// The page appleid.apple.com would have served (usually an auto-submitting form_post page or a redirect).
    case response(HTTPURLResponse, Data)
    /// No native handling (e.g. the browser lacks Apple's entitlement): use the web flow.
    case notHandled
    case cancelled
    case failed(Error)
}

protocol AppleSignInSession: AnyObject {
    func cancel()
}

protocol AppleSignInProvider: AnyObject {
    func canHandle(_ url: URL) -> Bool
    func begin(_ url: URL, initiatorOrigin: String?, userInitiated: Bool, events: @escaping (AppleSignInEvent) -> Void) -> AppleSignInSession
}

/// Apple's AppSSO (`SOAuthorization`, the mechanism Safari and WebKit use), driven through the Objective-C runtime
/// with WebKit's AppSSOSPI.h signatures. The Apple ID extension serves only browsers holding
/// `com.apple.developer.web-browser.public-key-credential`; others get `notHandled` (verified on an ad-hoc build).
final class AppSSOProvider: AppleSignInProvider {
    static let loaded = dlopen("/System/Library/PrivateFrameworks/AppSSO.framework/AppSSO", RTLD_NOW) != nil
    private var authorizationClass: NSObject.Type? { Self.loaded ? NSClassFromString("SOAuthorization") as? NSObject.Type : nil }

    func canHandle(_ url: URL) -> Bool {
        guard let cls = authorizationClass else { return false }
        let sel = NSSelectorFromString("canPerformAuthorizationWithURL:responseCode:useInternalExtensions:")
        guard let method = class_getClassMethod(cls, sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSURL, Int, Bool) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, sel, url as NSURL, 0, true)
    }

    func begin(_ url: URL, initiatorOrigin: String?, userInitiated: Bool, events: @escaping (AppleSignInEvent) -> Void) -> AppleSignInSession {
        let session = AppSSOSession(events: events)
        guard let cls = authorizationClass else {
            DispatchQueue.main.async { events(.notHandled) }
            return session
        }
        let authorization = cls.init()
        session.authorization = authorization
        authorization.setValue(session.delegate, forKey: "delegate")
        authorization.setValue(DispatchQueue.main, forKey: "delegateDispatchQueue")
        authorization.setValue(true, forKey: "enableEmbeddedAuthorizationViewController")
        var options: [String: Any] = ["SOAuthorizationOptionUserActionInitiated": userInitiated]
        if let initiatorOrigin { options["initiatorOrigin"] = initiatorOrigin }
        authorization.setValue(options, forKey: "authorizationOptions")
        let sel = NSSelectorFromString("beginAuthorizationWithURL:httpHeaders:httpBody:")
        guard let method = class_getInstanceMethod(cls, sel) else {
            DispatchQueue.main.async { events(.notHandled) }
            return session
        }
        typealias Fn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, NSData) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(authorization, sel, url as NSURL, [:] as NSDictionary, Data() as NSData)
        return session
    }
}

final class AppSSOSession: AppleSignInSession {
    var authorization: NSObject?
    let delegate: AppSSODelegate

    init(events: @escaping (AppleSignInEvent) -> Void) {
        delegate = AppSSODelegate(events: events)
    }

    func cancel() {
        authorization?.perform(NSSelectorFromString("cancelAuthorization"))
    }
}

/// Implements `SOAuthorizationDelegate` (declared at runtime: the protocol is private).
final class AppSSODelegate: NSObject {
    private var events: ((AppleSignInEvent) -> Void)?

    init(events: @escaping (AppleSignInEvent) -> Void) {
        self.events = events
        super.init()
        if let proto = objc_getProtocol("SOAuthorizationDelegate") { class_addProtocol(Self.self, proto) }
    }

    /// One outcome per attempt (presenting the sheet isn't one).
    private func finish(_ event: AppleSignInEvent) {
        events?(event)
        events = nil
    }

    @objc(authorizationDidNotHandle:) func didNotHandle(_ authorization: AnyObject) { finish(.notHandled) }
    @objc(authorizationDidCancel:) func didCancel(_ authorization: AnyObject) { finish(.cancelled) }
    @objc(authorizationDidComplete:) func didComplete(_ authorization: AnyObject) { finish(.cancelled) }
    @objc(authorization:didCompleteWithHTTPAuthorizationHeaders:) func didComplete(_ authorization: AnyObject, headers: NSDictionary) {
        finish(.notHandled)
    }
    @objc(authorization:didCompleteWithHTTPResponse:httpBody:) func didComplete(_ authorization: AnyObject, response: HTTPURLResponse, body: Data) {
        finish(.response(response, body))
    }
    @objc(authorization:didCompleteWithError:) func didFail(_ authorization: AnyObject, error: NSError) { finish(.failed(error)) }
    @objc(authorization:presentViewController:withCompletion:)
    func present(_ authorization: AnyObject, viewController: NSViewController, completion: @escaping (Bool, NSError?) -> Void) {
        events?(.present(viewController))
        completion(true, nil)
    }
}
