// CEF bridge: Chrome-style browsers, one frameless CefWindow per tab (docs/decisions/0002).
#import "CEFBridge.h"

#include <crt_externs.h>
#include <objc/runtime.h>

#include <atomic>
#include <cmath>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_color_ids.h"
#include "include/cef_command_ids.h"
#include "include/cef_stream.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_overlay_controller.h"
#include "include/views/cef_panel.h"
#include "include/views/cef_scroll_view.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/base/cef_callback.h"

// MARK: - Helpers

static NSString *NS(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }
static CefString CS(NSString *s) { return CefString(s ? s.UTF8String : ""); }

// MARK: - Cookies

/// Collects one site's cookies; CEF releases the visitor once it has seen every cookie (or none could be read), and
/// the collected list goes to `completion` then.
class SiteCookieCollector : public CefCookieVisitor {
public:
    SiteCookieCollector(std::string site, void (^completion)(NSArray *)) : site_(site), completion_(completion) {}
    ~SiteCookieCollector() override {
        NSArray *cookies = [cookies_ copy];
        void (^completion)(NSArray *) = completion_;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cookies); });
    }
    bool Visit(const CefCookie &cookie, int, int, bool &) override {
        std::string domain = CefString(&cookie.domain).ToString();
        std::string host = !domain.empty() && domain[0] == '.' ? domain.substr(1) : domain;
        bool matches = host == site_ || (host.size() > site_.size() && host.compare(host.size() - site_.size() - 1, std::string::npos, "." + site_) == 0);
        if (!matches) return true;
        NSMutableDictionary *c = [@{@"name": NS(CefString(&cookie.name)), @"value": NS(CefString(&cookie.value)), @"domain": NS(domain),
                                    @"path": NS(CefString(&cookie.path)), @"secure": @(cookie.secure != 0), @"httpOnly": @(cookie.httponly != 0)} mutableCopy];
        cef_time_t expires;
        double seconds = 0;
        if (cookie.has_expires && cef_time_from_basetime(cookie.expires, &expires) && cef_time_to_doublet(&expires, &seconds))
            c[@"expires"] = [NSDate dateWithTimeIntervalSince1970:seconds];
        switch (cookie.same_site) {
            case CEF_COOKIE_SAME_SITE_LAX_MODE: c[@"sameSite"] = @"lax"; break;
            case CEF_COOKIE_SAME_SITE_STRICT_MODE: c[@"sameSite"] = @"strict"; break;
            case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: c[@"sameSite"] = @"none"; break;
            default: break;
        }
        [cookies_ addObject:c];
        return true;
    }

private:
    std::string site_;
    void (^completion_)(NSArray *);
    NSMutableArray *cookies_ = [NSMutableArray array];
    IMPLEMENT_REFCOUNTING(SiteCookieCollector);
};

// MARK: - Page windows

static IMP gWindowIsMainWindow;

/// Chromium's page view takes mouse moves (hover, the cursor) only in a main or key window, and a page window, a child
/// of the browser window, is never main: after a click in the sidebar, the page showed no hover until clicked. A page
/// window is main whenever its browser window is.
static BOOL PageWindowIsMainWindow(NSWindow *self, SEL _cmd) {
    if (((BOOL (*)(id, SEL))gWindowIsMainWindow)(self, _cmd)) return YES;
    return self.parentWindow.isMainWindow;
}

static void PageWindowsFollowTheirBrowserWindow() {
    Class page = NSClassFromString(@"CefNSWindow");
    if (!page || gWindowIsMainWindow) return;
    Method method = class_getInstanceMethod(page, @selector(isMainWindow));
    gWindowIsMainWindow = method_getImplementation(method);
    class_replaceMethod(page, @selector(isMainWindow), (IMP)PageWindowIsMainWindow, method_getTypeEncoding(method));
}

// MARK: - NSApplication

@interface BrowserCEFApplication () <CefAppProtocol> {
    BOOL _handlingSendEvent;
}
@end

@implementation BrowserCEFApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }
- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent scoped;
    [self focusPageForMouseDown:event];
    [super sendEvent:event];
}

/// Pages are child windows of the browser window, so a click going from the sidebar (or an overlay) to the page is
/// a first click in a window that isn't key, which Chromium's page view refuses: the page window takes key first.
/// Only within the browser window that has focus: a click that activates the app still only activates it, as in Safari.
- (void)focusPageForMouseDown:(NSEvent *)event {
    NSEventType type = event.type;
    if (type != NSEventTypeLeftMouseDown && type != NSEventTypeRightMouseDown && type != NSEventTypeOtherMouseDown) return;
    NSWindow *page = event.window;
    NSWindow *browser = page.parentWindow;
    static Class pageClass = NSClassFromString(@"CefNSWindow");
    if (!browser || page.isKeyWindow || ![page isKindOfClass:pageClass] || !page.canBecomeKeyWindow) return;
    for (NSWindow *w = self.keyWindow; w; w = w.parentWindow) {
        if (w == browser) {
            [page makeKeyWindow];
            return;
        }
    }
}
@end

// MARK: - Tab internals

@class CEFTab;

@interface CEFTab ()
- (instancetype)initDetachedPopup;
- (void)attachBrowserView:(CefRefPtr<CefBrowserView>)view;
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
- (CefRefPtr<CefClient>)client;
- (CefRefPtr<CefBrowserViewDelegate>)viewDelegate;
- (void)installExtensionToolbar:(CefRefPtr<CefView>)toolbar window:(CefRefPtr<CefWindow>)window;
- (void)removeExtensionToolbar;
- (void)pageWindowBoundsChanged;
- (void)extensionToolbarWidthChanged:(int)width;
- (void)placeToolbarContent;
- (CefRect)toolbarOverlayBounds;
@property (nonatomic) CEFDisposition pendingDisposition;
@property (nonatomic) BOOL pendingGesture;
@property (nonatomic, copy, nullable) NSString *pendingURL;
@property (nonatomic) BOOL isClosing;
@property (nonatomic, readwrite) BOOL isPrivate;
@property (nonatomic, readonly) BOOL isAnchor;
- (instancetype)initAnchor;
@end

@interface CEFRuntime ()
- (CefRefPtr<CefRequestContext>)privateContextFor:(CEFTab *)tab;
- (void)registerTab:(CEFTab *)tab;
- (void)unregisterTab:(CEFTab *)tab;
- (void)updateAnchor;
- (void)allowAnchor;
- (CefRefPtr<CefDictionaryValue>)extraInfo;
- (nullable NSString *)filter:(const std::string &)url firstParty:(const std::string &)fp type:(const char *)type;
- (void)chromeOpened:(NSString *)url;
- (void)chromeOpenedTab:(CEFTab *)tab;
- (NSString *)downloadPathFor:(NSString *)name url:(NSString *)url;
- (void)download:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

static const char *ResourceTypeName(cef_resource_type_t t) {
    switch (t) {
        case RT_MAIN_FRAME: return "document";
        case RT_SUB_FRAME: return "subdocument";
        case RT_STYLESHEET: return "stylesheet";
        case RT_SCRIPT: case RT_WORKER: case RT_SHARED_WORKER: case RT_SERVICE_WORKER: return "script";
        case RT_IMAGE: case RT_FAVICON: return "image";
        case RT_FONT_RESOURCE: return "font";
        case RT_XHR: return "xhr";
        case RT_MEDIA: return "media";
        case RT_PING: case RT_CSP_REPORT: return "ping";
        default: return "other";
    }
}

/// One tab's network filtering (IO thread), plus responses the browser serves itself (`simulate`).
class FilterHandler : public CefResourceRequestHandler {
public:
    struct Simulated {
        int status;
        std::string statusText, mimeType;
        CefResponse::HeaderMap headers;
        std::string body;
    };

    /// The next request for `url` gets this response instead of going to the network (once).
    void Simulate(const std::string &url, Simulated response) {
        std::lock_guard<std::mutex> lock(mutex_);
        simulated_[url] = std::move(response);
    }

    CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                     CefRefPtr<CefRequest> request) override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = simulated_.find(request->GetURL().ToString());
        if (it == simulated_.end()) return nullptr;
        Simulated r = std::move(it->second);
        simulated_.erase(it);
        CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForData(r.body.data(), r.body.size());
        return new CefStreamResourceHandler(r.status, r.statusText, r.mimeType, r.headers, stream);
    }

    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback> callback) override {
        std::string url = request->GetURL().ToString();
        if (url.rfind("http", 0) != 0 && url.rfind("ws", 0) != 0) return RV_CONTINUE;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (simulated_.count(url)) return RV_CONTINUE;
        }
        std::string fp = request->GetReferrerURL().ToString();
        if (frame) { std::string f = frame->GetURL().ToString(); if (!f.empty()) fp = f; }
        NSString *verdict = [[CEFRuntime shared] filter:url firstParty:fp type:ResourceTypeName(request->GetResourceType())];
        if (!verdict) return RV_CONTINUE;
        if (verdict.length == 0) return RV_CANCEL;
        // A body to answer with (Chromium won't redirect subresources to data: URLs): GetResourceHandler serves it.
        if ([verdict hasPrefix:@"data:"]) {
            NSRange comma = [verdict rangeOfString:@","];
            if (comma.location == NSNotFound) return RV_CANCEL;
            NSString *meta = [verdict substringWithRange:NSMakeRange(5, comma.location - 5)];
            NSData *body = [[NSData alloc] initWithBase64EncodedString:[verdict substringFromIndex:comma.location + 1] options:0];
            if (!body) return RV_CANCEL;
            Simulated response{200, "OK", [meta componentsSeparatedByString:@";"].firstObject.UTF8String ?: "text/plain", {},
                               std::string(static_cast<const char *>(body.bytes), body.length)};
            response.headers.insert({"Access-Control-Allow-Origin", "*"});
            Simulate(url, std::move(response));
            return RV_CONTINUE;
        }
        request->SetURL(CS(verdict));  // an internal redirect: the new URL is filtered again
        return RV_CONTINUE;
    }

private:
    std::mutex mutex_;
    std::map<std::string, Simulated> simulated_;
    IMPLEMENT_REFCOUNTING(FilterHandler);
};

/// DevTools windows: CEF's own window, none of a page's handlers. Without a client of their own they would get the
/// default client, which adopts Chrome-made windows as tabs (a DevTools tab cut off from the page it inspects).
class DevToolsClient : public CefClient {
    IMPLEMENT_REFCOUNTING(DevToolsClient);
};

/// Per-tab client: routes every CEF callback to the ObjC tab (UI thread unless noted).
class TabClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
                  public CefRequestHandler, public CefKeyboardHandler, public CefFindHandler, public CefPermissionHandler,
                  public CefDownloadHandler, public CefCommandHandler, public CefDevToolsMessageObserver,
                  public CefJSDialogHandler, public CefContextMenuHandler {
public:
    explicit TabClient(CEFTab *tab) : tab_(tab), filter_(new FilterHandler) {}

    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

    // The page's context menu (a native menu): without the items that open Chrome's own UI (QR code, sharing, sending to
    // devices, translation, Lens, Gemini, Chrome's reading mode and split view), and with the private space in place of
    // Chrome's incognito window.
    static constexpr int kOpenLinkPrivately = MENU_ID_USER_FIRST + 1;
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override {
        int incognito = model->GetIndexOf(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD);
        if (incognito >= 0) {
            model->RemoveAt(incognito);
            model->InsertItemAt(incognito, kOpenLinkPrivately, "Open Link in Private Tab");
        }
        for (int id : {IDC_CONTENT_CONTEXT_GENERATE_QR_CODE, IDC_CONTENT_CONTEXT_SHARING_SUBMENU, IDC_SEND_TAB_TO_SELF,
                       IDC_CONTENT_CONTEXT_SEND_TAB_TO_SELF_DEVICE1, IDC_CONTENT_CONTEXT_SEND_TAB_TO_SELF_MANAGE_DEVICES, IDC_QRCODE_GENERATOR,
                       IDC_SHARING_HUB, IDC_CONTENT_CONTEXT_TRANSLATE, IDC_CONTENT_CONTEXT_PARTIAL_TRANSLATE, IDC_CONTENT_CONTEXT_LENS_REGION_SEARCH,
                       IDC_CONTENT_CONTEXT_LENS_OVERLAY, IDC_CONTENT_CONTEXT_SEARCHLENSFORIMAGE, IDC_CONTENT_CONTEXT_SEARCHLENSFORVIDEOFRAME,
                       IDC_CONTENT_CONTEXT_GLICSHAREIMAGE, IDC_CONTENT_CONTEXT_GLIC, IDC_CONTENT_CONTEXT_RELOAD_GLIC, IDC_CONTENT_CONTEXT_ARCHIVE_GLIC,
                       IDC_CONTENT_CONTEXT_OPEN_IN_READING_MODE, IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW, IDC_CONTENT_CONTEXT_OPENLINKINPROFILE}) {
            while (model->Remove(id)) {}
        }
        // No separator first, last or twice in a row once items are gone.
        for (size_t i = model->GetCount(); i-- > 0;) {
            bool separator = model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR;
            bool edge = i == 0 || i + 1 == model->GetCount();
            if (separator && (edge || model->GetTypeAt(i - 1) == MENUITEMTYPE_SEPARATOR)) model->RemoveAt(i);
        }
        if (model->GetCount() > 0 && model->GetTypeAt(0) == MENUITEMTYPE_SEPARATOR) model->RemoveAt(0);
    }
    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                              int command_id, EventFlags event_flags) override {
        CEFTab *tab = tab_;
        if (command_id != kOpenLinkPrivately || !tab.delegate) return false;
        [tab.delegate cefTab:tab openPrivately:NS(params->GetLinkUrl())];
        return true;
    }

    // Failed loads and invalid certificates: the browser's own pages instead of Chrome's.
    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString &errorText,
                     const CefString &failedUrl) override {
        CEFTab *tab = tab_;
        if (!frame->IsMain() || errorCode == ERR_ABORTED || !tab.delegate) return;
        [tab.delegate cefTab:tab loadFailed:NS(failedUrl) code:(int)errorCode text:NS(errorText)];
    }
    bool OnCertificateError(CefRefPtr<CefBrowser> browser, cef_errorcode_t cert_error, const CefString &request_url,
                            CefRefPtr<CefSSLInfo> ssl_info, CefRefPtr<CefCallback> callback) override {
        CEFTab *tab = tab_;
        int decision = tab.delegate ? [tab.delegate cefTab:tab certificateErrorFor:NS(request_url)] : -1;
        if (decision < 0) return false;
        if (decision > 0) callback->Continue(); else callback->Cancel();
        return true;
    }

    // Page dialogs: the browser's own UI instead of Chrome's tab-modal dialogs.
    bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString &origin_url, JSDialogType type, const CefString &message_text,
                    const CefString &default_prompt_text, CefRefPtr<CefJSDialogCallback> callback, bool &suppress_message) override {
        NSString *kind = type == JSDIALOGTYPE_CONFIRM ? @"confirm" : type == JSDIALOGTYPE_PROMPT ? @"prompt" : @"alert";
        return ShowDialog(kind, NS(message_text), NS(default_prompt_text), NS(origin_url), callback);
    }
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message_text, bool is_reload,
                              CefRefPtr<CefJSDialogCallback> callback) override {
        return ShowDialog(is_reload ? @"reload" : @"leave", NS(message_text), @"", NS(browser->GetMainFrame()->GetURL()), callback);
    }
    bool ShowDialog(NSString *kind, NSString *message, NSString *defaultText, NSString *origin, CefRefPtr<CefJSDialogCallback> callback) {
        CEFTab *tab = tab_;
        if (!tab.delegate) return false;
        return [tab.delegate cefTab:tab dialog:kind message:message defaultText:defaultText origin:origin
                              reply:^(BOOL accepted, NSString *text) { callback->Continue(accepted, CS(text ?: @"")); }];
    }

    // A site's sign-in: asked on the IO thread, answered from the main thread.
    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString &origin_url, bool isProxy, const CefString &host, int port,
                            const CefString &realm, const CefString &scheme, CefRefPtr<CefAuthCallback> callback) override {
        if (![CEFRuntime shared].handlesSignIn) return false;
        __weak CEFTab *weakTab = tab_;
        NSString *hostName = NS(host), *realmName = NS(realm), *origin = NS(origin_url);
        dispatch_async(dispatch_get_main_queue(), ^{
            CEFTab *tab = weakTab;
            if (!tab.delegate) { callback->Cancel(); return; }
            [tab.delegate cefTab:tab signInFor:hostName realm:realmName proxy:isProxy origin:origin reply:^(NSString *user, NSString *password) {
                if (user) callback->Continue(CS(user), CS(password ?: @"")); else callback->Cancel();
            }];
        });
        return true;
    }

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }

    // Life span
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id, const CefString &target_url,
                       const CefString &target_frame_name, WindowOpenDisposition disposition, bool user_gesture,
                       const CefPopupFeatures &features, CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                       CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info, bool *no_javascript_access) override {
        CEFTab *opener = tab_;
        if (!opener) return true;
        if (disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE) return false;  // Chrome hosts document PiP itself
        CEFTab *popup = [[CEFTab alloc] initDetachedPopup];
        popup.isPrivate = opener.isPrivate;  // CEF gives popups their opener's request context
        popup.pendingURL = NS(target_url);
        popup.pendingGesture = user_gesture;
        switch (disposition) {
            case CEF_WOD_NEW_BACKGROUND_TAB: popup.pendingDisposition = CEFDispositionBackgroundTab; break;
            case CEF_WOD_NEW_POPUP: popup.pendingDisposition = CEFDispositionPopup; break;
            case CEF_WOD_NEW_WINDOW: popup.pendingDisposition = CEFDispositionNewWindow; break;
            default: popup.pendingDisposition = CEFDispositionForegroundTab; break;
        }
        client = [popup client];
        extra_info = [[CEFRuntime shared] extraInfo];
        pendingPopups_.push_back(popup);
        return false;
    }

    // ⌥⌘I and Chrome's "Inspect" both come here.
    void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser, CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                               CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info, bool *use_default_window) override {
        client = new DevToolsClient;
    }

    CEFTab *TakePendingPopup() {
        if (pendingPopups_.empty()) return nil;
        CEFTab *p = pendingPopups_.front();
        pendingPopups_.pop_front();
        return p;
    }

    CEFTab *PeekPendingPopup() { return pendingPopups_.empty() ? nil : pendingPopups_.front(); }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { [tab_ browserCreated:browser]; }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        CEFTab *tab = tab_;
        if (tab && !tab.isClosing) {
            // window.close() from the page: let the runtime decide (it will call -close).
            [tab.delegate cefTabRequestsClose:tab];
            return true;
        }
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        devtools_ = nullptr;  // the registration holds this client
        [tab_ browserClosed];
    }

    // Display
    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
        if (frame->IsMain()) [tab_.delegate cefTab:tab_ addressChanged:NS(url)];
    }
    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        [tab_.delegate cefTab:tab_ titleChanged:NS(title)];
    }
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString> &icon_urls) override {
        [tab_.delegate cefTab:tab_ faviconChanged:icon_urls.empty() ? nil : NS(icon_urls[0])];
    }
    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
        [tab_.delegate cefTab:tab_ fullscreenChanged:fullscreen];
    }
    void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString &value) override {
        std::string v = value.ToString();
        [tab_.delegate cefTab:tab_ statusChanged:v.empty() ? nil : NS(value)];
    }
    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        [tab_.delegate cefTab:tab_ progressChanged:progress];
    }
    void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool video, bool audio) override {
        [tab_.delegate cefTab:tab_ mediaAccessVideo:video audio:audio];
    }

    // Load
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
        [tab_.delegate cefTab:tab_ loadingChanged:isLoading canGoBack:canGoBack canGoForward:canGoForward];
    }
    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition) override {
        if (frame->IsMain()) [tab_.delegate cefTab:tab_ didCommit:NS(frame->GetURL())];
    }
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
        if (frame->IsMain()) [tab_.delegate cefTabDidFinishLoad:tab_];
    }

    // Requests
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                        bool user_gesture, bool is_redirect) override {
        if (!frame->IsMain() || !tab_.delegate) return false;
        BOOL allowed = [tab_.delegate cefTab:tab_ shouldNavigateTo:NS(request->GetURL()) userGesture:user_gesture isRedirect:is_redirect];
        if (allowed) {
            NSString *url = NS(request->GetURL());
            SetDocumentStartScript(browser, url, [tab_.delegate cefTab:tab_ documentStartScriptFor:url]);
        }
        return !allowed;
    }

    /// The navigation's document-start script, through DevTools (Page.addScriptToEvaluateOnNewDocument): Chromium runs it
    /// in the new document before the page's scripts, even across a process swap. Replaces the previous navigation's.
    /// DevTools attaches only once a page gets a script.
    void SetDocumentStartScript(CefRefPtr<CefBrowser> browser, NSString *url, NSString *script) {
        if (scriptID_.empty() && pendingAdd_ == 0 && !script.length) return;
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        if (!devtools_) {
            devtools_ = host->AddDevToolsMessageObserver(this);
            host->ExecuteDevToolsMethod(0, "Page.enable", nullptr);  // Blink applies these scripts only with Page enabled
        }
        if (!scriptID_.empty()) {
            CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
            params->SetString("identifier", scriptID_);
            host->ExecuteDevToolsMethod(0, "Page.removeScriptToEvaluateOnNewDocument", params);
            scriptID_.clear();
        }
        if (pendingAdd_) staleAdds_.insert(pendingAdd_);  // removed as soon as its identifier arrives
        pendingAdd_ = 0;
        if (!script.length) return;
        // Top document only, and only on the navigation's host (a script that outlives its navigation, e.g. a redirect
        // before its identifier came back, never runs elsewhere).
        NSData *hostJSON = [NSJSONSerialization dataWithJSONObject:@[[NSURL URLWithString:url].host ?: @""] options:0 error:nil];
        NSString *hostLiteral = [[NSString alloc] initWithData:hostJSON encoding:NSUTF8StringEncoding];
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetString("source", CS([NSString stringWithFormat:@"if (window === window.top && location.hostname === %@[0]) {\n%@\n}",
                                                                   hostLiteral, script]));
        pendingAdd_ = host->ExecuteDevToolsMethod(0, "Page.addScriptToEvaluateOnNewDocument", params);
    }

    /// The visible page as PNG, from the renderer (Page.captureScreenshot): a GPU-drawn page can't be cached from its view.
    void CaptureScreenshot(CefRefPtr<CefBrowser> browser, void (^completion)(NSData *)) {
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        if (!devtools_) devtools_ = host->AddDevToolsMessageObserver(this);
        CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
        params->SetString("format", "png");
        int id = host->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
        if (id) captures_[id] = [completion copy]; else completion(nil);
    }

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result, size_t result_size) override {
        auto capture = captures_.find(message_id);
        if (capture != captures_.end()) {
            void (^done)(NSData *) = capture->second;
            captures_.erase(capture);
            CefRefPtr<CefValue> value = success ? CefParseJSON(result, result_size, JSON_PARSER_RFC) : nullptr;
            std::string data = value && value->GetType() == VTYPE_DICTIONARY ? value->GetDictionary()->GetString("data").ToString() : "";
            done(data.empty() ? nil : [[NSData alloc] initWithBase64EncodedString:NS(data) options:0]);
            return;
        }
        bool current = message_id == pendingAdd_;
        bool stale = staleAdds_.erase(message_id) > 0;
        if ((!current && !stale) || !success) { if (current) pendingAdd_ = 0; return; }
        CefRefPtr<CefValue> value = CefParseJSON(result, result_size, JSON_PARSER_RFC);
        std::string id = value && value->GetType() == VTYPE_DICTIONARY ? value->GetDictionary()->GetString("identifier").ToString() : "";
        if (current) { pendingAdd_ = 0; scriptID_ = id; return; }
        if (!id.empty()) {
            CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
            params->SetString("identifier", id);
            browser->GetHost()->ExecuteDevToolsMethod(0, "Page.removeScriptToEvaluateOnNewDocument", params);
        }
    }

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &target_url,
                          WindowOpenDisposition disposition, bool user_gesture) override {
        // "Open Link in New Tab" and friends: becomes our own child tab.
        if (disposition == CEF_WOD_CURRENT_TAB) return false;
        CEFTab *tab = tab_;
        CEFTab *opened = [[CEFTab alloc] initWithURL:NS(target_url) delegate:nil private:tab.isPrivate];
        CEFDisposition d = disposition == CEF_WOD_NEW_BACKGROUND_TAB ? CEFDispositionBackgroundTab
                         : disposition == CEF_WOD_NEW_WINDOW ? CEFDispositionNewWindow : CEFDispositionForegroundTab;
        [tab.delegate cefTab:tab didOpen:opened url:NS(target_url) disposition:d userGesture:user_gesture];
        return true;
    }

    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                                   CefRefPtr<CefRequest> request, bool is_navigation, bool is_download,
                                                                   const CefString &request_initiator, bool &disable_default_handling) override {
        return filter_;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                   const CefString &error_string) override {
        [tab_.delegate cefTabDidCrash:tab_];
    }

    // Messages from the renderer helper: page posts (window.__browser.post) and eval results. The sending
    // frame comes from the browser process, so pages can't lie about it.
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        BOOL main = frame && frame->IsMain();
        NSString *frameURL = frame ? NS(frame->GetURL()) : nil;
        if (message->GetName() == "browser.evalResult") {
            [tab_.delegate cefTab:tab_ message:@"__eval" json:NS(args->GetString(0)) mainFrame:main frameURL:frameURL];
            return true;
        }
        if (message->GetName() != "browser.post") return false;
        NSString *name = NS(args->GetString(0));
        if ([name isEqualToString:@"__eval"]) return true;  // only the renderer answers evals
        [tab_.delegate cefTab:tab_ message:name json:NS(args->GetString(1)) mainFrame:main frameURL:frameURL];
        return true;
    }

    // Keyboard: browser shortcuts go to the native menu first, unless the page should see them first; then the menu
    // gets them after the page, if the page didn't handle them.
    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event,
                       bool *is_keyboard_shortcut) override {
        if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) return false;
        if (!(event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_CONTROL_DOWN))) return false;
        if ([tab_.delegate cefTab:tab_ prefersPageForKey:(__bridge NSEvent *)os_event]) {
            *is_keyboard_shortcut = true;
            return false;
        }
        return [tab_.delegate cefTab:tab_ handleKeyEquivalent:(__bridge NSEvent *)os_event];
    }

    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event) override {
        if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) return false;
        if (!(event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_CONTROL_DOWN))) return false;
        // Only page-first shortcuts get here unhandled (the menu declined the others before the page).
        return [tab_.delegate cefTab:tab_ handleKeyEquivalent:(__bridge NSEvent *)os_event];
    }

    // Find
    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect &selectionRect, int active,
                      bool finalUpdate) override {
        [tab_.delegate cefTab:tab_ findResultCount:count active:active];
    }

    // Permissions
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &origin,
                                        uint32_t requested, CefRefPtr<CefMediaAccessCallback> callback) override {
        NSMutableArray *kinds = [NSMutableArray array];
        if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [kinds addObject:@"camera"];
        if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [kinds addObject:@"microphone"];
        if (requested & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) [kinds addObject:@"screenCapture"];
        if (!tab_.delegate) return false;
        [tab_.delegate cefTab:tab_ requestsPermissions:kinds origin:NS(origin) reply:^(BOOL granted) {
            CefPostTask(TID_UI, base::BindOnce([](CefRefPtr<CefMediaAccessCallback> cb, uint32_t mask) { cb->Continue(mask); },
                                               callback, granted ? requested : (uint32_t)CEF_MEDIA_PERMISSION_NONE));
        }];
        return true;
    }

    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString &origin, uint32_t requested,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        NSMutableArray *kinds = [NSMutableArray array];
        if (requested & CEF_PERMISSION_TYPE_GEOLOCATION) [kinds addObject:@"location"];
        if (requested & CEF_PERMISSION_TYPE_NOTIFICATIONS) [kinds addObject:@"notifications"];
        if (requested & CEF_PERMISSION_TYPE_CLIPBOARD) [kinds addObject:@"clipboard"];
        if (requested & CEF_PERMISSION_TYPE_MIDI_SYSEX) [kinds addObject:@"midi"];
        if (kinds.count == 0 || !tab_.delegate) return false;
        [tab_.delegate cefTab:tab_ requestsPermissions:kinds origin:NS(origin) reply:^(BOOL granted) {
            CefPostTask(TID_UI, base::BindOnce([](CefRefPtr<CefPermissionPromptCallback> cb, bool ok) {
                cb->Continue(ok ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
            }, callback, (bool)granted));
        }];
        return true;
    }

    // Downloads
    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, const CefString &suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        NSString *path = [[CEFRuntime shared] downloadPathFor:NS(suggested_name) url:NS(item->GetURL())];
        if (!path) return false;
        callback->Continue(CS(path), false);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        [[CEFRuntime shared] download:item callback:callback];
    }

    // Chrome's own commands (its accelerators, app menu) are disabled: our menus own every action, and run the few
    // Chrome commands they need through -runChromeCommand:.
    bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id, cef_window_open_disposition_t disposition) override {
        if (command_id != allowedCommand_) return true;
        allowedCommand_ = 0;
        return false;
    }
    void AllowChromeCommand(int command_id) { allowedCommand_ = command_id; }

    /// The Chrome toolbar only exists for extension actions: none of its other buttons (each may preload UI).
    bool IsChromeToolbarButtonVisible(cef_chrome_toolbar_button_type_t) override { return false; }

    void Detach() { tab_ = nil; }
    CefRefPtr<FilterHandler> filter() { return filter_; }

private:
    __weak CEFTab *tab_;
    CefRefPtr<FilterHandler> filter_;
    std::deque<CEFTab *> pendingPopups_;
    CefRefPtr<CefRegistration> devtools_;
    int allowedCommand_ = 0;
    std::map<int, void (^)(NSData *)> captures_;
    std::string scriptID_;
    int pendingAdd_ = 0;
    std::set<int> staleAdds_;
    IMPLEMENT_REFCOUNTING(TabClient);
};

/// Gives a panel a fixed preferred size (the hidden toolbar's virtual width).
class SizedPanelDelegate : public CefPanelDelegate {
public:
    explicit SizedPanelDelegate(CefSize size) : size(size) {}
    CefSize GetPreferredSize(CefRefPtr<CefView>) override { return size; }
    CefSize size;
    IMPLEMENT_REFCOUNTING(SizedPanelDelegate);
};

/// DevTools windows are CEF's own: no toolbar.
class DevToolsViewDelegate : public CefBrowserViewDelegate {
public:
    ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
    IMPLEMENT_REFCOUNTING(DevToolsViewDelegate);
};

/// Chrome style; popups are adopted as tabs. With `extensionToolbar`, each page carries Chrome's real toolbar
/// in a 1×1 overlay (docs/decisions/0003): invisible, but its extension actions, popups and bubbles are Chrome's own.
class ViewDelegate : public CefBrowserViewDelegate {
public:
    explicit ViewDelegate(CEFTab *tab) : tab_(tab) {}
    cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
    ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override {
        return [CEFRuntime shared].extensionToolbar && !tab_.isAnchor ? CEF_CTT_NORMAL : CEF_CTT_NONE;
    }

    void OnWindowChanged(CefRefPtr<CefView> view, bool added) override {
        CEFTab *tab = tab_;
        if (!added) return;  // the toolbar is handed back in browserClosed, before the window closes
        CefRefPtr<CefBrowserView> browserView = view->AsBrowserView();
        CefRefPtr<CefView> toolbar = browserView ? browserView->GetChromeToolbar() : nullptr;
        if (toolbar && view->GetWindow()) [tab installExtensionToolbar:toolbar window:view->GetWindow()];
    }

    CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(CefRefPtr<CefBrowserView> view, const CefBrowserSettings &settings,
                                                                     CefRefPtr<CefClient> client, bool is_devtools) override {
        if (is_devtools) return new DevToolsViewDelegate;
        TabClient *tc = static_cast<TabClient *>([tab_ client].get());
        CEFTab *popup = tc ? tc->PeekPendingPopup() : nil;
        return popup ? [popup viewDelegate] : CefRefPtr<CefBrowserViewDelegate>(this);
    }

    bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowserView> popupView, bool is_devtools) override {
        if (is_devtools) return false;  // DevTools get their own window
        CEFTab *opener = tab_;
        TabClient *tc = static_cast<TabClient *>([opener client].get());
        CEFTab *popup = tc ? tc->TakePendingPopup() : nil;
        if (!popup) return false;
        [popup attachBrowserView:popupView];
        if (opener.isAnchor) [[CEFRuntime shared] chromeOpenedTab:popup];
        else [opener.delegate cefTab:opener didOpen:popup url:popup.pendingURL disposition:popup.pendingDisposition userGesture:popup.pendingGesture];
        return true;
    }

private:
    __weak CEFTab *tab_;
    IMPLEMENT_REFCOUNTING(ViewDelegate);
};

static const cef_color_t kPageBackground = CefColorSetARGB(255, 255, 255, 255);

/// The page window: frameless, never shown by CEF (the Swift viewport orders it in as a child window).
class PageWindowDelegate : public CefWindowDelegate {
public:
    PageWindowDelegate(CEFTab *tab, CefRefPtr<CefBrowserView> view) : tab_(tab), view_(view) {}
    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        window_ = window;
        SetPageColors(window);
        window->ThemeChanged();
        window->AddChildView(view_);
    }
    /// Chrome's theme gives pages without a background its web-contents color: dark gray in Dark Mode. Pages
    /// stay white, as in Safari (they still get `prefers-color-scheme: dark` to style themselves).
    void OnThemeColorsChanged(CefRefPtr<CefWindow> window, bool chromeTheme) override {
        SetPageColors(window);
    }
    /// Pages render with a transparent canvas here, over the window's primary background (dark gray in Dark
    /// Mode): pages without a background stay white, as in Safari. Only this window's views are affected (its page
    /// and the invisible toolbar); Chrome's bubbles are separate widgets with the normal theme.
    static void SetPageColors(CefRefPtr<CefWindow> window) {
        window->SetThemeColor(CEF_ColorPrimaryBackground, kPageBackground);
        window->SetThemeColor(CEF_ColorWebContentsBackground, kPageBackground);
    }
    void OnWindowDestroyed(CefRefPtr<CefWindow> window) override { view_ = nullptr; window_ = nullptr; }
    bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
    void OnWindowBoundsChanged(CefRefPtr<CefWindow>, const CefRect &) override { [tab_ pageWindowBoundsChanged]; }
    bool CanResize(CefRefPtr<CefWindow>) override { return true; }
    bool CanClose(CefRefPtr<CefWindow>) override { return true; }
    CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(-20000, -20000, 1024, 768); }
    cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
    CefRefPtr<CefWindow> window() { return window_; }

private:
    __weak CEFTab *tab_;
    CefRefPtr<CefBrowserView> view_;
    CefRefPtr<CefWindow> window_;
    IMPLEMENT_REFCOUNTING(PageWindowDelegate);
};

// MARK: - CEFTab

/// Collects the back/forward list (CEF calls it synchronously on the UI thread, which is the main thread here).
class EntryCollector : public CefNavigationEntryVisitor {
public:
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    NSInteger current = -1;
    bool Visit(CefRefPtr<CefNavigationEntry> entry, bool isCurrent, int index, int) override {
        [entries addObject:@{@"url": [NSString stringWithUTF8String:entry->GetURL().ToString().c_str()] ?: @"",
                             @"title": [NSString stringWithUTF8String:entry->GetTitle().ToString().c_str()] ?: @""}];
        if (isCurrent) current = index;
        return true;
    }
    IMPLEMENT_REFCOUNTING(EntryCollector);
};

@implementation CEFTab {
    CefRefPtr<TabClient> _client;
    CefRefPtr<ViewDelegate> _viewDelegate;
    CefRefPtr<CefBrowserView> _view;
    CefRefPtr<PageWindowDelegate> _windowDelegate;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<CefOverlayController> _toolbarOverlay;
    CefRefPtr<CefScrollView> _toolbarScroll;
    CefRefPtr<CefPanel> _toolbarFull;
    CefRefPtr<CefView> _toolbarView;
    CefRefPtr<SizedPanelDelegate> _toolbarSize;
    NSMutableArray<void (^)(void)> *_pending;
    double _zoomLevel;
    BOOL _muted;
}

- (instancetype)initDetachedPopup {
    if ((self = [super init])) {
        _client = new TabClient(self);
        _viewDelegate = new ViewDelegate(self);
        _pending = [NSMutableArray array];
        [[CEFRuntime shared] registerTab:self];
    }
    return self;
}

- (instancetype)initWithURL:(NSString *)url delegate:(id<CEFTabDelegate>)delegate private:(BOOL)isPrivate {
    if ((self = [self initDetachedPopup])) {
        _delegate = delegate;
        _isPrivate = isPrivate;
        [self createBrowserWithURL:url];
    }
    return self;
}

/// No page and never shown: the Chrome window extensions start from while no page has one (`CEFRuntime updateAnchor`).
- (instancetype)initAnchor {
    if ((self = [self initDetachedPopup])) {
        _isAnchor = YES;
        [self createBrowserWithURL:nil];
    }
    return self;
}

- (void)createBrowserWithURL:(NSString *)url {
    CefBrowserSettings settings;
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);
    CefRefPtr<CefRequestContext> context = _isPrivate ? [[CEFRuntime shared] privateContextFor:self] : nullptr;
    CefRefPtr<CefBrowserView> view = CefBrowserView::CreateBrowserView(_client, CS(url ?: @""), settings,
                                                                       [[CEFRuntime shared] extraInfo], context, _viewDelegate);
    [self attachBrowserView:view];
}

- (void)attachBrowserView:(CefRefPtr<CefBrowserView>)view {
    _view = view;
    _windowDelegate = new PageWindowDelegate(self, view);
    CefWindow::CreateTopLevelWindow(_windowDelegate);
    NSWindow *w = self.window;
    w.hasShadow = NO;
    w.backgroundColor = NSColor.clearColor;
    w.opaque = NO;
    w.releasedWhenClosed = NO;
    w.animationBehavior = NSWindowAnimationBehaviorNone;
    w.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    if (view->GetBrowser()) [self browserCreated:view->GetBrowser()];
}

- (CefRefPtr<CefClient>)client { return _client; }
- (CefRefPtr<CefBrowserViewDelegate>)viewDelegate { return _viewDelegate; }

- (NSWindow *)window {
    if (!_windowDelegate || !_windowDelegate->window()) return nil;
    NSView *handle = (__bridge NSView *)_windowDelegate->window()->GetWindowHandle();
    return handle.window;
}

- (BOOL)isReady { return _browser != nullptr; }

- (NSString *)currentURL { return _browser ? NS(_browser->GetMainFrame()->GetURL()) : nil; }

- (void)browserCreated:(CefRefPtr<CefBrowser>)browser {
    if (_browser) return;
    _browser = browser;

    NSArray *pending = [_pending copy];
    [_pending removeAllObjects];
    for (void (^block)(void) in pending) block();
}

- (void)browserClosed {
    // Closed by Chrome, not by us (`chrome.tabs.remove` from an extension…): the tab goes too.
    id<CEFTabDelegate> closedByChrome = self.isClosing ? nil : self.delegate;
    [self removeExtensionToolbar];
    _browser = nullptr;
    if (_client) _client->Detach();
    __weak NSWindow *window = self.window;
    if (_windowDelegate && _windowDelegate->window()) _windowDelegate->window()->Close();
    // The anchor's window, never shown, stays open (invisible) after that: close it as AppKit would.
    if (_isAnchor) dispatch_async(dispatch_get_main_queue(), ^{ [window close]; });
    [[CEFRuntime shared] unregisterTab:self];
    [closedByChrome cefTabRequestsClose:self];
}

// MARK: Hidden extension toolbar (docs/decisions/0003)

- (void)installExtensionToolbar:(CefRefPtr<CefView>)toolbar window:(CefRefPtr<CefWindow>)window {
    if (_toolbarOverlay) return;
    _toolbarSize = new SizedPanelDelegate(CefSize(MAX([CEFRuntime shared].extensionToolbarWidth, 320), 46));
    CefRefPtr<CefPanel> full = CefPanel::CreatePanel(_toolbarSize);
    full->SetToFillLayout();
    full->AddChildView(toolbar);
    _toolbarFull = full;
    _toolbarView = toolbar;
    // A 1×1 scroll view clips the full-size toolbar: nothing shows, while anchors keep their unclipped screen
    // bounds, so Chrome's bubbles open where the (virtual) buttons are, next to the sidebar. A scroll view, not a
    // panel: its content keeps the size we give it, where layouts would squeeze the toolbar to its minimum.
    _toolbarScroll = CefScrollView::CreateScrollView(nullptr);
    _toolbarScroll->SetContentView(full);
    _toolbarOverlay = window->AddOverlayView(_toolbarScroll, CEF_DOCKING_MODE_CUSTOM, false);
    // CEF adds an empty view above the page as the overlay's z-order reference, and the window's fill layout
    // stretches it over the whole page. Chromium routes clicks by the view under the pointer, so that view took
    // every click meant for the page: the page goes back on top.
    if (_view) window->ReorderChildView(_view, -1);
    _toolbarOverlay->SetBounds([self toolbarOverlayBounds]);
    _toolbarOverlay->SetVisible(true);
    [self placeToolbarContent];
}

/// Before the page window closes, the toolbar goes back into that window (hidden): Chrome's browser view keeps
/// a pointer to it, and only the window's own teardown destroys the two in a safe order. Left in the overlay
/// (another widget), it is deleted first and closing the window crashes.
- (void)removeExtensionToolbar {
    CefRefPtr<CefWindow> window = _windowDelegate ? _windowDelegate->window() : nullptr;
    if (_toolbarFull && _toolbarView && window) {
        _toolbarFull->RemoveChildView(_toolbarView);
        _toolbarView->SetVisible(false);
        window->AddChildView(_toolbarView);
    }
    if (_toolbarOverlay && _toolbarOverlay->IsValid()) _toolbarOverlay->Destroy();
    _toolbarOverlay = nullptr;
    _toolbarScroll = nullptr;
    _toolbarFull = nullptr;
    _toolbarView = nullptr;
    _toolbarSize = nullptr;
}

/// Custom-docked overlays don't follow the window when the viewport moves it.
- (void)pageWindowBoundsChanged {
    if (_toolbarOverlay && _toolbarOverlay->IsValid()) _toolbarOverlay->SetBounds([self toolbarOverlayBounds]);
}

- (void)extensionToolbarWidthChanged:(int)width {
    if (!_toolbarSize || !_toolbarFull) return;
    _toolbarSize->size = CefSize(MAX(width, 320), 46);
    [self placeToolbarContent];
}

/// Sizes the toolbar: only once it is in a widget, since laying out Chrome's toolbar outside one crashes.
- (void)placeToolbarContent {
    CefSize size = _toolbarSize->size;
    _toolbarFull->SetSize(size);
    if (_toolbarOverlay && _toolbarOverlay->IsValid()) _toolbarOverlay->SetBounds([self toolbarOverlayBounds]);
}

/// The 1×1 overlay sits where the toolbar starts, so that the toolbar ends at the page's top-right corner:
/// Chrome opens popups there, as users expect. (Its extension buttons can't sit by the sidebar: Chrome shows
/// pinned actions only from ~560 pt wide, and overlays can't start left of the page.)
- (CefRect)toolbarOverlayBounds {
    CefRefPtr<CefWindow> window = _windowDelegate ? _windowDelegate->window() : nullptr;
    int width = window ? window->GetBounds().width : 0, toolbar = _toolbarSize ? _toolbarSize->size.width : 0;
    return CefRect(MAX(0, width - toolbar), 0, 1, 1);
}

/// The overlay's NSWindow: the page's 1×1 child window.
- (NSWindow *)toolbarWindow {
    if (!_toolbarOverlay) return nil;
    for (NSWindow *child in self.window.childWindows)
        if (NSEqualSizes(child.frame.size, NSMakeSize(1, 1))) return child;
    return nil;
}

static NSArray *AXKids(id e) {
    return [e respondsToSelector:@selector(accessibilityChildren)] ? ([e accessibilityChildren] ?: @[]) : @[];
}
static NSString *AXRole(id e) { return [e respondsToSelector:@selector(accessibilityRole)] ? [e accessibilityRole] : nil; }
static NSString *AXName(id e) {
    NSString *label = [e respondsToSelector:@selector(accessibilityLabel)] ? [e accessibilityLabel] : nil;
    if (label.length) return label;
    return [e respondsToSelector:@selector(accessibilityTitle)] ? [e accessibilityTitle] : nil;
}
static BOOL AXContainsRole(id e, NSString *role, int depth) {
    if ([AXRole(e) isEqualToString:role]) return YES;
    if (depth > 8) return NO;
    for (id k in AXKids(e)) if (AXContainsRole(k, role, depth + 1)) return YES;
    return NO;
}
/// Chrome's extensions container, found by structure (labels are localized): the group whose last child is the
/// extensions menu button and that holds no text field (the location bar has the omnibox).
static id AXExtensionsContainer(id e, int depth) {
    if (depth > 12) return nil;
    NSArray *kids = AXKids(e);
    if (kids.count && [AXRole(kids.lastObject) isEqualToString:NSAccessibilityPopUpButtonRole]
        && ![AXRole(e) isEqualToString:NSAccessibilityToolbarRole] && ![AXRole(e) isEqualToString:NSAccessibilityWindowRole]
        && !AXContainsRole(e, NSAccessibilityTextFieldRole, 0)) return e;
    for (id k in kids) if (id found = AXExtensionsContainer(k, depth + 1)) return found;
    return nil;
}
static id AXButtonNamed(id e, NSString *name, int depth) {
    if ([AXRole(e) isEqualToString:NSAccessibilityButtonRole] && [AXName(e) isEqualToString:name]) return e;
    if (depth > 14) return nil;
    for (id k in AXKids(e)) if (id found = AXButtonNamed(k, name, depth + 1)) return found;
    return nil;
}

- (BOOL)showExtensionsMenu {
    id container = AXExtensionsContainer(self.toolbarWindow, 0);
    return container ? [AXKids(container).lastObject accessibilityPerformPress] : NO;
}

- (NSArray<NSArray<NSString *> *> *)extensionActionBadges {
    NSMutableArray<NSArray<NSString *> *> *badges = [NSMutableArray array];
    id container = AXExtensionsContainer(self.toolbarWindow, 0);
    NSArray *buttons = container ? AXKids(container) : @[];
    for (id button in buttons) {
        if (button == buttons.lastObject) continue;  // the extensions menu
        NSString *name = AXName(button);
        // Chromium puts a view's description in its custom accessibility content on macOS ("description").
        NSString *badge = nil;
        if ([button respondsToSelector:@selector(accessibilityCustomContent)]) {
            for (id item in [button performSelector:@selector(accessibilityCustomContent)]) {
                if ([[item valueForKey:@"label"] isEqual:@"description"]) badge = [item valueForKey:@"value"];
            }
        }
        if (!badge.length && [button respondsToSelector:@selector(accessibilityHelp)]) badge = [button accessibilityHelp];
        [badges addObject:@[name ?: @"", badge.length && ![badge isEqualToString:name] ? badge : @""]];
    }
    return badges;
}

- (void)runExtensionActionNamed:(NSString *)name completion:(void (^)(BOOL))completion {
    NSWindow *toolbarWindow = self.toolbarWindow;
    id container = AXExtensionsContainer(toolbarWindow, 0);
    if (!container) { completion(NO); return; }
    // The page is Chrome's active window as the action runs, so what the extension asks for (a permission, to remove
    // itself) comes over this page. Clicked in the sidebar, the browser window is key instead, and Chrome would pick its
    // newest page window, maybe a hidden tab's.
    NSWindow *page = self.window;
    if (NSApp.isActive && page.isVisible && !page.isKeyWindow) [page makeKeyWindow];
    for (id button in AXKids(container)) {
        if (button != AXKids(container).lastObject && [AXName(button) hasPrefix:name]) { completion([button accessibilityPerformPress]); return; }
    }
    // Not pinned: Chrome's menu runs it (and briefly pops the action out, like a click in Chrome would).
    if (![AXKids(container).lastObject accessibilityPerformPress]) { completion(NO); return; }
    __weak NSWindow *weakToolbar = toolbarWindow;
    __block int attempts = 0;
    __block void (^poll)(void);
    void (^tryPress)(void) = ^{
        for (NSWindow *menu in weakToolbar.childWindows) {
            if (id item = AXButtonNamed(menu, name, 0)) { completion([item accessibilityPerformPress]); poll = nil; return; }
        }
        if (++attempts > 40) { completion(NO); poll = nil; return; }
        void (^next)(void) = poll;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), next);
    };
    poll = tryPress;
    tryPress();
}

- (void)whenReady:(void (^)(void))block {
    if (_browser) block(); else [_pending addObject:[block copy]];
}

- (void)loadURL:(NSString *)url {
    __weak CEFTab *weakSelf = self;
    [self whenReady:^{ CEFTab *s = weakSelf; if (s) s->_browser->GetMainFrame()->LoadURL(CS(url)); }];
}
- (void)loadURL:(NSString *)url simulatingStatus:(int)status statusText:(NSString *)statusText
          headers:(NSDictionary<NSString *, NSString *> *)headers body:(NSData *)body {
    FilterHandler::Simulated r;
    r.status = status;
    r.statusText = statusText.UTF8String ?: "";
    NSString *type = headers[@"Content-Type"] ?: headers[@"content-type"] ?: @"text/html";
    r.mimeType = [type componentsSeparatedByString:@";"].firstObject.UTF8String;
    for (NSString *key in headers) r.headers.insert(std::make_pair(CS(key), CS(headers[key])));
    r.body.assign((const char *)body.bytes, body.length);
    if (_client) _client->filter()->Simulate(url.UTF8String, std::move(r));
    [self loadURL:url];
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)print { if (_browser) _browser->GetHost()->Print(); }

- (NSArray<NSDictionary<NSString *, NSString *> *> *)navigationEntriesWithCurrentIndex:(NSInteger *)currentIndex {
    *currentIndex = -1;
    if (!_browser) return @[];
    CefRefPtr<EntryCollector> collector = new EntryCollector();
    _browser->GetHost()->GetNavigationEntries(collector, false);
    *currentIndex = collector->current;
    return collector->entries;
}
- (void)reloadIgnoringCache:(BOOL)ignore { if (_browser) { ignore ? _browser->ReloadIgnoreCache() : _browser->Reload(); } }
- (void)stopLoad { if (_browser) _browser->StopLoad(); }

- (void)executeJavaScript:(NSString *)code {
    __weak CEFTab *weakSelf = self;
    [self whenReady:^{ CEFTab *s = weakSelf; if (s) s->_browser->GetMainFrame()->ExecuteJavaScript(CS(code), "", 0); }];
}

- (void)evaluate:(NSString *)code identifier:(int)identifier {
    __weak CEFTab *weakSelf = self;
    [self whenReady:^{
        CEFTab *s = weakSelf;
        if (!s) return;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create("browser.eval");
        message->GetArgumentList()->SetInt(0, identifier);
        message->GetArgumentList()->SetString(1, CS(code));
        s->_browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
    }];
}

- (double)zoomLevel { return _browser ? _browser->GetHost()->GetZoomLevel() : _zoomLevel; }
- (void)setZoomLevel:(double)level {
    _zoomLevel = level;
    __weak CEFTab *weakSelf = self;
    [self whenReady:^{ CEFTab *s = weakSelf; if (s) s->_browser->GetHost()->SetZoomLevel(level); }];
}

- (BOOL)muted { return _muted; }
- (void)setMuted:(BOOL)muted {
    _muted = muted;
    __weak CEFTab *weakSelf = self;
    [self whenReady:^{ CEFTab *s = weakSelf; if (s) s->_browser->GetHost()->SetAudioMuted(muted); }];
}

- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
    if (_browser) _browser->GetHost()->Find(CS(text), forward, matchCase, findNext);
}
- (void)stopFinding { if (_browser) _browser->GetHost()->StopFinding(true); }

- (void)showDevTools {
    if (!_browser) return;
    CefWindowInfo info;
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

static_assert(CEFChromeCommandSavePage == IDC_SAVE_PAGE && CEFChromeCommandConsole == IDC_DEV_TOOLS_CONSOLE &&
              CEFChromeCommandInspect == IDC_DEV_TOOLS_INSPECT, "Chrome command ids changed");

- (void)captureScreenshot:(void (^)(NSData *))completion {
    if (!_browser || !_client) return completion(nil);
    _client->CaptureScreenshot(_browser, completion);
}

- (void)runChromeCommand:(int)commandID {
    if (!_browser || !_client) return;
    _client->AllowChromeCommand(commandID);
    _browser->GetHost()->ExecuteChromeCommand(commandID, CEF_WOD_CURRENT_TAB);
}

- (void)setFocus:(BOOL)focus { if (_browser) _browser->GetHost()->SetFocus(focus); }

- (void)close {
    if (self.isClosing) return;
    self.isClosing = YES;
    _delegate = nil;
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
    } else if (_windowDelegate && _windowDelegate->window()) {
        _windowDelegate->window()->Close();
        [[CEFRuntime shared] unregisterTab:self];
    }
}
@end

// MARK: - Default client (browsers Chrome creates on its own)

/// Extension `chrome.tabs.create`, Chrome-created windows…: hand the URL to the runtime, close the stock window.
class AdoptingClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler {
public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        if (NSView *v = (__bridge NSView *)browser->GetHost()->GetWindowHandle()) [v.window orderOut:nil];
    }
    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
        std::string u = url.ToString();
        if (!frame->IsMain() || u.empty() || u == "about:blank" || adopted_.count(browser->GetIdentifier())) return;
        adopted_.insert(browser->GetIdentifier());
        [[CEFRuntime shared] chromeOpened:NS(url)];
        browser->GetHost()->CloseBrowser(true);
    }
private:
    std::set<int> adopted_;
    IMPLEMENT_REFCOUNTING(AdoptingClient);
};

/// Foundation property-list values as CEF values (preferences may be dictionaries and lists).
static CefRefPtr<CefValue> ToCefValue(id v) {
    CefRefPtr<CefValue> value = CefValue::Create();
    if ([v isKindOfClass:NSString.class]) value->SetString(CS(v));
    else if ([v isKindOfClass:NSDictionary.class]) {
        CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
        for (NSString *key in (NSDictionary *)v) dict->SetValue(CS(key), ToCefValue(((NSDictionary *)v)[key]));
        value->SetDictionary(dict);
    } else if ([v isKindOfClass:NSArray.class]) {
        CefRefPtr<CefListValue> list = CefListValue::Create();
        for (id item in (NSArray *)v) list->SetValue(list->GetSize(), ToCefValue(item));
        value->SetList(list);
    } else if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) value->SetBool([v boolValue]);
    else if (strcmp([v objCType], @encode(double)) == 0 || strcmp([v objCType], @encode(float)) == 0) value->SetDouble([v doubleValue]);
    else value->SetInt([v intValue]);
    return value;
}

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit BrowserApp(NSDictionary<NSString *, NSString *> *switches) : switches_(switches), adopting_(new AdoptingClient) {}
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefClient> GetDefaultClient() override { return adopting_; }
    void OnContextInitialized() override {
        CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
        NSDictionary<NSString *, id> *prefs = [CEFRuntime shared].profilePreferences;
        for (NSString *name in prefs) {
            CefString error;
            if (!context->SetPreference(CS(name), ToCefValue(prefs[name]), error)) NSLog(@"CEF preference %@ not set: %s", name, error.ToString().c_str());
        }
        [CEFRuntime shared].contextReady = YES;
        [[CEFRuntime shared] allowAnchor];
    }
    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line) override {
        for (NSString *key in switches_) {
            NSString *value = switches_[key];
            // Feature lists are merged: replacing CEF's own disable-features list crashes at startup.
            if (([key isEqualToString:@"disable-features"] || [key isEqualToString:@"enable-features"]) && command_line->HasSwitch(CS(key))) {
                std::string existing = command_line->GetSwitchValue(CS(key)).ToString();
                value = [NSString stringWithFormat:@"%s,%@", existing.c_str(), value];
            }
            if (value.length) command_line->AppendSwitchWithValue(CS(key), CS(value));
            else command_line->AppendSwitch(CS(key));
        }
    }
private:
    NSDictionary<NSString *, NSString *> *switches_;
    CefRefPtr<AdoptingClient> adopting_;
    IMPLEMENT_REFCOUNTING(BrowserApp);
};

// MARK: - Runtime

@implementation CEFRuntime {
    CefScopedLibraryLoader *_loader;
    CefRefPtr<BrowserApp> _app;
    NSHashTable<CEFTab *> *_tabs;
    NSMutableSet<CEFTab *> *_retained;
    CefRefPtr<CefRequestContext> _privateContext;
    std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _downloadCallbacks;
    void (^_allClosed)(void);
    CEFTab *_anchor;
    BOOL _anchorAllowed;
    BOOL _quitting;
}

+ (instancetype)shared {
    static CEFRuntime *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CEFRuntime alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _tabs = [NSHashTable weakObjectsHashTable];
        _retained = [NSMutableSet set];
        _userScripts = @[];
        _extensionToolbarWidth = 360;
        _profilePreferences = @{};
    }
    return self;
}

- (void)setProfilePreference:(NSString *)name value:(id)value {
    NSMutableDictionary *prefs = [self.profilePreferences mutableCopy];
    prefs[name] = value;
    self.profilePreferences = prefs;
    if (!self.contextReady) return;  // applied when the context is initialized
    CefString error;
    if (!CefRequestContext::GetGlobalContext()->SetPreference(CS(name), ToCefValue(value), error))
        NSLog(@"CEF preference %@ not set: %s", name, error.ToString().c_str());
}

- (BOOL)loadLibrary {
    if (_loader) return YES;
    _loader = new CefScopedLibraryLoader();
    return _loader->LoadInMain();
}

- (BOOL)initializeWithRootCachePath:(NSString *)path switches:(NSDictionary<NSString *, NSString *> *)switches error:(NSError **)error {
    // The real argv, so Chromium switches work from the command line (`--enable-logging=stderr`, `--v=1`…).
    CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.no_sandbox = true;
    // Pages without a background are white, as in Chrome and Safari (CEF's default follows the dark theme).
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);
    settings.persist_session_cookies = true;
    CefString(&settings.root_cache_path) = CS(path);
    CefString(&settings.cache_path) = CS([path stringByAppendingPathComponent:@"Default"]);
    NSString *locale = NSLocale.preferredLanguages.firstObject ?: @"en-US";
    CefString(&settings.locale) = CS(locale);
    _app = new BrowserApp(switches);
    if (!CefInitialize(args, settings, _app.get(), nullptr)) {
        if (error) *error = [NSError errorWithDomain:@"CEF" code:CefGetExitCode() userInfo:@{NSLocalizedDescriptionKey: @"CefInitialize failed"}];
        return NO;
    }
    PageWindowsFollowTheirBrowserWindow();
    return YES;
}

- (void)setExtensionsInstalled:(BOOL)installed {
    _extensionsInstalled = installed;
    [self updateAnchor];
}

- (void)setExtensionToolbarWidth:(int)width {
    _extensionToolbarWidth = width;
    for (CEFTab *tab in _tabs) [tab extensionToolbarWidthChanged:width];
}

- (void)runMessageLoop { CefRunMessageLoop(); }
- (void)quitMessageLoop { CefQuitMessageLoop(); }
- (void)shutdown { CefShutdown(); }

/// Private windows: an off-the-record profile (memory only; Chrome style makes one for a context without a cache path),
/// shared by private tabs until the last one closes.
/// A private tab opened while every other private tab is closing (Chrome closes browsers asynchronously) starts a new
/// session: the one closing must not leak into it.
- (CefRefPtr<CefRequestContext>)privateContextFor:(CEFTab *)tab {
    BOOL others = NO;
    for (CEFTab *t in _retained) if (t != tab && t.isPrivate && !t.isClosing) { others = YES; break; }
    if (!others) _privateContext = nullptr;
    if (!_privateContext) {
        CefRequestContextSettings settings;
        _privateContext = CefRequestContext::CreateContext(settings, nullptr);
    }
    return _privateContext;
}

- (void)registerTab:(CEFTab *)tab {
    [_tabs addObject:tab];
    [_retained addObject:tab];
    if (!tab.isAnchor && !tab.isPrivate) [self updateAnchor];
}

/// Extensions' `chrome.tabs.create` starts from Chrome's current window ("No current window" without one), and here
/// each page is a window of its own: with no page open (a first launch, an empty window), welcome pages were lost. An
/// anchor (no page, never shown) stands in until a page opens; Chrome makes the tab in a window of its own, adopted as
/// any other. Only extensions see it, as a blank tab, and only while no page is open. Its cost: ~9 MB in this
/// process, no renderer (measured 2026-10-15; the hidden toolbar it doesn't get would add two); none without extensions.
/// Made first at startup, it delayed the restored page by ~150 ms: after a first launch it waits (`anchorStartupDelay`).
/// A first launch has nothing to restore, and extensions installing then open their welcome pages at once.
- (void)allowAnchor {
    void (^allow)(void) = ^{ self->_anchorAllowed = YES; [self updateAnchor]; };
    if (self.anchorStartupDelay <= 0) allow();
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.anchorStartupDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), allow);
}

- (void)updateAnchor {
    BOOL pages = NO;
    for (CEFTab *t in _retained) if (!t.isAnchor && !t.isPrivate && !t.isClosing) { pages = YES; break; }
    BOOL needed = _anchorAllowed && self.extensionsInstalled && !_quitting && !pages;
    if (needed && !_anchor) {
        _anchor = [[CEFTab alloc] initAnchor];
    } else if (!needed && _anchor) {
        CEFTab *anchor = _anchor;
        _anchor = nil;
        [anchor close];
    }
}

- (void)unregisterTab:(CEFTab *)tab {
    [_retained removeObject:tab];
    if (tab.isPrivate && _privateContext) {
        BOOL privateLeft = NO;
        for (CEFTab *t in _retained) if (t.isPrivate) { privateLeft = YES; break; }
        if (!privateLeft) _privateContext = nullptr;  // the session ends: the next private window starts empty
    }
    if (tab == _anchor) _anchor = nil;  // closed by Chrome (an extension closing every tab…)
    if (_allClosed && _retained.count == 0) {
        void (^done)(void) = _allClosed;
        _allClosed = nil;
        done();
    }
    // Not from inside Chrome's close callback.
    if (!_quitting) dispatch_async(dispatch_get_main_queue(), ^{ [self updateAnchor]; });
}

- (void)closeAllBrowsers:(void (^)(void))completion {
    _quitting = YES;
    _anchor = nil;  // closed with the pages below
    if (_retained.count == 0) { completion(); return; }
    _allClosed = [completion copy];
    for (CEFTab *tab in [_retained allObjects]) [tab close];
    // Safety net: never hang quit on a stuck renderer. A run-loop timer in every mode, because AppKit's
    // terminate-later wait does not drain the main dispatch queue.
    NSTimer *timer = [NSTimer timerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) {
        if (self->_allClosed) { void (^done)(void) = self->_allClosed; self->_allClosed = nil; done(); }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
}

- (CefRefPtr<CefDictionaryValue>)extraInfo {
    CefRefPtr<CefDictionaryValue> info = CefDictionaryValue::Create();
    CefRefPtr<CefListValue> list = CefListValue::Create();
    int i = 0;
    for (NSDictionary *s in self.userScripts) {
        CefRefPtr<CefDictionaryValue> d = CefDictionaryValue::Create();
        d->SetString("source", CS(s[@"source"]));
        d->SetBool("documentStart", [s[@"documentStart"] boolValue]);
        d->SetBool("mainFrameOnly", [s[@"mainFrameOnly"] boolValue]);
        list->SetDictionary(i++, d);
    }
    info->SetList("scripts", list);
    return info;
}

- (nullable NSString *)filter:(const std::string &)url firstParty:(const std::string &)fp type:(const char *)type {
    id<CEFRuntimeDelegate> d = self.delegate;
    if (!d) return nil;
    return [d cefFilterRequest:[NSString stringWithUTF8String:url.c_str()]
                    firstParty:fp.empty() ? nil : [NSString stringWithUTF8String:fp.c_str()]
                          type:[NSString stringWithUTF8String:type]];
}

- (void)chromeOpened:(NSString *)url { [self.delegate cefChromeOpenedURL:url]; }
- (void)chromeOpenedTab:(CEFTab *)tab { [self.delegate cefChromeOpenedTab:tab url:tab.pendingURL disposition:tab.pendingDisposition]; }

- (NSString *)downloadPathFor:(NSString *)name url:(NSString *)url {
    return [self.delegate cefDownloadPathForSuggestedName:name url:url];
}

- (void)download:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
    uint32_t identifier = item->GetId();
    if (item->IsComplete() || item->IsCanceled()) _downloadCallbacks.erase(identifier);
    else _downloadCallbacks[identifier] = callback;
    std::string path = item->GetFullPath().ToString();
    [self.delegate cefDownload:identifier url:NS(item->GetURL()) path:path.empty() ? nil : NS(item->GetFullPath())
                      received:item->GetReceivedBytes() total:item->GetTotalBytes()
                      complete:item->IsComplete() canceled:item->IsCanceled()];
}

- (void)cancelDownload:(uint32_t)identifier {
    auto it = _downloadCallbacks.find(identifier);
    if (it != _downloadCallbacks.end()) it->second->Cancel();
}

- (void)cookiesOfSite:(NSString *)site private:(BOOL)isPrivate completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion {
    CefRefPtr<CefRequestContext> context = isPrivate ? _privateContext : CefRequestContext::GetGlobalContext();
    CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
    CefRefPtr<SiteCookieCollector> collector = new SiteCookieCollector(site.lowercaseString.UTF8String, completion);
    if (manager) manager->VisitAllCookies(collector);
}
@end
