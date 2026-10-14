// CEF bridge: Chrome-style browsers, one frameless CefWindow per tab (docs/decisions/0002).
#import "CEFBridge.h"

#include <crt_externs.h>

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
#include "include/cef_parser.h"
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
    [super sendEvent:event];
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
@end

@interface CEFRuntime ()
- (void)registerTab:(CEFTab *)tab;
- (void)unregisterTab:(CEFTab *)tab;
- (CefRefPtr<CefDictionaryValue>)extraInfo;
- (BOOL)shouldBlock:(const std::string &)url firstParty:(const std::string &)fp type:(const char *)type;
- (void)chromeOpened:(NSString *)url;
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

/// Shared by every browser: network filtering (IO thread).
class FilterHandler : public CefResourceRequestHandler {
public:
    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback> callback) override {
        std::string url = request->GetURL().ToString();
        if (url.rfind("http", 0) != 0 && url.rfind("ws", 0) != 0) return RV_CONTINUE;
        std::string fp = request->GetReferrerURL().ToString();
        if (frame) { std::string f = frame->GetURL().ToString(); if (!f.empty()) fp = f; }
        if ([[CEFRuntime shared] shouldBlock:url firstParty:fp type:ResourceTypeName(request->GetResourceType())]) return RV_CANCEL;
        return RV_CONTINUE;
    }
    IMPLEMENT_REFCOUNTING(FilterHandler);
};

/// Per-tab client: routes every CEF callback to the ObjC tab (UI thread unless noted).
class TabClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler, public CefLoadHandler,
                  public CefRequestHandler, public CefKeyboardHandler, public CefFindHandler, public CefPermissionHandler,
                  public CefDownloadHandler, public CefCommandHandler {
public:
    explicit TabClient(CEFTab *tab) : tab_(tab), filter_(new FilterHandler) {}

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

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { [tab_ browserClosed]; }

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
        return !allowed;
    }

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &target_url,
                          WindowOpenDisposition disposition, bool user_gesture) override {
        // "Open Link in New Tab" and friends: becomes our own child tab.
        if (disposition == CEF_WOD_CURRENT_TAB) return false;
        CEFTab *tab = tab_;
        CEFTab *opened = [[CEFTab alloc] initWithURL:NS(target_url) delegate:nil];
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

    // Messages from the renderer helper (window.__browser.post).
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() != "browser.post") return false;
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        [tab_.delegate cefTab:tab_ message:NS(args->GetString(0)) json:NS(args->GetString(1))];
        return true;
    }

    // Keyboard: browser shortcuts go to the native menu first.
    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event,
                       bool *is_keyboard_shortcut) override {
        if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) return false;
        if (!(event.modifiers & (EVENTFLAG_COMMAND_DOWN | EVENTFLAG_CONTROL_DOWN))) return false;
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

    // Chrome's own commands (its accelerators, app menu) are disabled: our menus own every action.
    bool OnChromeCommand(CefRefPtr<CefBrowser> browser, int command_id, cef_window_open_disposition_t disposition) override {
        return true;
    }

    /// The Chrome toolbar only exists for extension actions: none of its other buttons (each may preload UI).
    bool IsChromeToolbarButtonVisible(cef_chrome_toolbar_button_type_t) override { return false; }

    void Detach() { tab_ = nil; }

private:
    __weak CEFTab *tab_;
    CefRefPtr<FilterHandler> filter_;
    std::deque<CEFTab *> pendingPopups_;
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
        return [CEFRuntime shared].extensionToolbar ? CEF_CTT_NORMAL : CEF_CTT_NONE;
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
        [opener.delegate cefTab:opener didOpen:popup url:popup.pendingURL disposition:popup.pendingDisposition userGesture:popup.pendingGesture];
        return true;
    }

private:
    __weak CEFTab *tab_;
    IMPLEMENT_REFCOUNTING(ViewDelegate);
};

/// The page window: frameless, never shown by CEF (the Swift viewport orders it in as a child window).
class PageWindowDelegate : public CefWindowDelegate {
public:
    PageWindowDelegate(CEFTab *tab, CefRefPtr<CefBrowserView> view) : tab_(tab), view_(view) {}
    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        window_ = window;
        window->AddChildView(view_);
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

- (instancetype)initWithURL:(NSString *)url delegate:(id<CEFTabDelegate>)delegate {
    if ((self = [self initDetachedPopup])) {
        _delegate = delegate;
        CefBrowserSettings settings;
        CefRefPtr<CefBrowserView> view = CefBrowserView::CreateBrowserView(_client, CS(url ?: @""), settings,
                                                                           [[CEFRuntime shared] extraInfo], nullptr, _viewDelegate);
        [self attachBrowserView:view];
    }
    return self;
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
    [self removeExtensionToolbar];
    _browser = nullptr;
    if (_client) _client->Detach();
    if (_windowDelegate && _windowDelegate->window()) _windowDelegate->window()->Close();
    [[CEFRuntime shared] unregisterTab:self];
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

- (void)runExtensionActionNamed:(NSString *)name completion:(void (^)(BOOL))completion {
    NSWindow *toolbarWindow = self.toolbarWindow;
    id container = AXExtensionsContainer(toolbarWindow, 0);
    if (!container) { completion(NO); return; }
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
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
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

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit BrowserApp(NSDictionary<NSString *, NSString *> *switches) : switches_(switches), adopting_(new AdoptingClient) {}
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefClient> GetDefaultClient() override { return adopting_; }
    void OnContextInitialized() override {
        CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
        NSDictionary<NSString *, id> *prefs = [CEFRuntime shared].profilePreferences;
        for (NSString *name in prefs) {
            id v = prefs[name];
            CefRefPtr<CefValue> value = CefValue::Create();
            if ([v isKindOfClass:NSString.class]) value->SetString(CS(v));
            else if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) value->SetBool([v boolValue]);
            else if (strcmp([v objCType], @encode(double)) == 0 || strcmp([v objCType], @encode(float)) == 0) value->SetDouble([v doubleValue]);
            else value->SetInt([v intValue]);
            CefString error;
            if (!context->SetPreference(CS(name), value, error)) NSLog(@"CEF preference %@ not set: %s", name, error.ToString().c_str());
        }
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
    std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _downloadCallbacks;
    void (^_allClosed)(void);
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
    return YES;
}

- (void)setExtensionToolbarWidth:(int)width {
    _extensionToolbarWidth = width;
    for (CEFTab *tab in _tabs) [tab extensionToolbarWidthChanged:width];
}

- (void)runMessageLoop { CefRunMessageLoop(); }
- (void)quitMessageLoop { CefQuitMessageLoop(); }
- (void)shutdown { CefShutdown(); }

- (void)registerTab:(CEFTab *)tab {
    [_tabs addObject:tab];
    [_retained addObject:tab];
}

- (void)unregisterTab:(CEFTab *)tab {
    [_retained removeObject:tab];
    if (_allClosed && _retained.count == 0) {
        void (^done)(void) = _allClosed;
        _allClosed = nil;
        done();
    }
}

- (void)closeAllBrowsers:(void (^)(void))completion {
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

- (BOOL)shouldBlock:(const std::string &)url firstParty:(const std::string &)fp type:(const char *)type {
    id<CEFRuntimeDelegate> d = self.delegate;
    if (!d) return NO;
    return [d cefShouldBlockRequest:[NSString stringWithUTF8String:url.c_str()]
                         firstParty:fp.empty() ? nil : [NSString stringWithUTF8String:fp.c_str()]
                               type:[NSString stringWithUTF8String:type]];
}

- (void)chromeOpened:(NSString *)url { [self.delegate cefChromeOpenedURL:url]; }

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
@end
