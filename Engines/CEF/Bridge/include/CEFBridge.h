// Objective-C surface over CEF (Chrome style), consumed by the Swift engine.
// Each tab is a frameless Chrome-style CefWindow hosting one CefBrowserView (docs/decisions/0002).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass implementing CefAppProtocol (CEF requires it as NSPrincipalClass).
@interface BrowserCEFApplication : NSApplication
@end

typedef NS_ENUM(NSInteger, CEFDisposition) {
    CEFDispositionForegroundTab = 0,
    CEFDispositionBackgroundTab = 1,
    CEFDispositionPopup = 2,
    CEFDispositionNewWindow = 3,
};

@class CEFTab;

@protocol CEFTabDelegate <NSObject>
- (void)cefTab:(CEFTab *)tab addressChanged:(NSString *)url;
- (void)cefTab:(CEFTab *)tab titleChanged:(NSString *)title;
- (void)cefTab:(CEFTab *)tab faviconChanged:(nullable NSString *)url;
- (void)cefTab:(CEFTab *)tab loadingChanged:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)cefTab:(CEFTab *)tab progressChanged:(double)progress;
- (void)cefTab:(CEFTab *)tab didCommit:(NSString *)url;
- (void)cefTabDidFinishLoad:(CEFTab *)tab;
- (void)cefTab:(CEFTab *)tab statusChanged:(nullable NSString *)status;
- (void)cefTab:(CEFTab *)tab mediaAccessVideo:(BOOL)video audio:(BOOL)audio;
- (void)cefTab:(CEFTab *)tab fullscreenChanged:(BOOL)fullscreen;
- (void)cefTab:(CEFTab *)tab findResultCount:(int)count active:(int)active;
/// Main-frame navigation decision (UI thread). Return NO to cancel.
- (BOOL)cefTab:(CEFTab *)tab shouldNavigateTo:(NSString *)url userGesture:(BOOL)gesture isRedirect:(BOOL)redirect;
/// The page opened `newTab` (popup, target=_blank, ⌘-click, context menu "Open in New Tab").
- (void)cefTab:(CEFTab *)tab didOpen:(CEFTab *)newTab url:(nullable NSString *)url disposition:(CEFDisposition)disposition userGesture:(BOOL)gesture;
/// `window.__browser.post(name, body)`; `json` is `JSON.stringify(body)`.
- (void)cefTab:(CEFTab *)tab message:(NSString *)name json:(NSString *)json;
- (void)cefTabRequestsClose:(CEFTab *)tab;
- (void)cefTabDidCrash:(CEFTab *)tab;
/// Key down with ⌘/⌃ before the page sees it. Return YES when the browser consumed it (menu shortcut).
- (BOOL)cefTab:(CEFTab *)tab handleKeyEquivalent:(NSEvent *)event;
/// Kinds: camera, microphone, screenCapture, location, notifications, clipboard, midi.
- (void)cefTab:(CEFTab *)tab requestsPermissions:(NSArray<NSString *> *)kinds origin:(NSString *)origin
         reply:(void (^)(BOOL granted))reply;
@end

@protocol CEFRuntimeDelegate <NSObject>
/// Called on the IO thread for every request: must be fast and thread-safe. Return YES to block.
- (BOOL)cefShouldBlockRequest:(NSString *)url firstParty:(nullable NSString *)firstParty type:(NSString *)type;
/// Where to save a download (UI thread). nil cancels.
- (nullable NSString *)cefDownloadPathForSuggestedName:(NSString *)name url:(nullable NSString *)url;
- (void)cefDownload:(uint32_t)identifier url:(NSString *)url path:(nullable NSString *)path received:(int64_t)received
              total:(int64_t)total complete:(BOOL)complete canceled:(BOOL)canceled;
/// Chrome opened a page on its own (extension `chrome.tabs.create`, …). The runtime should open it as a tab.
- (void)cefChromeOpenedURL:(NSString *)url;
@end

@interface CEFRuntime : NSObject
+ (instancetype)shared;
@property (weak, nullable) id<CEFRuntimeDelegate> delegate;
/// Scripts injected in every frame's main world at context creation: {source, documentStart (BOOL), mainFrameOnly (BOOL)}.
@property (copy) NSArray<NSDictionary<NSString *, id> *> *userScripts;
/// Profile preferences applied when the default request context is initialized (bool, number or string values).
@property (copy) NSDictionary<NSString *, id> *profilePreferences;
/// Loads the framework (main process). Call before anything else.
- (BOOL)loadLibrary;
- (BOOL)initializeWithRootCachePath:(NSString *)path
                           switches:(NSDictionary<NSString *, NSString *> *)switches
                              error:(NSError **)error;
- (void)runMessageLoop;
- (void)quitMessageLoop;
- (void)closeAllBrowsers:(void (^)(void))completion;
- (void)shutdown;
- (void)cancelDownload:(uint32_t)identifier;
@end

@interface CEFTab : NSObject
- (instancetype)initWithURL:(nullable NSString *)url delegate:(nullable id<CEFTabDelegate>)delegate;
@property (weak, nullable) id<CEFTabDelegate> delegate;
/// The page's own frameless window (exists right after init; the browser itself is created asynchronously).
@property (readonly, nullable) NSWindow *window;
@property (readonly) BOOL isReady;
@property (readonly, nullable) NSString *currentURL;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reloadIgnoringCache:(BOOL)ignoreCache;
- (void)stopLoad;
- (void)executeJavaScript:(NSString *)code;
/// Evaluates in the main frame's context through the renderer (not subject to page CSP); the result arrives
/// as message `__eval` with JSON `{id, ok, value | error}`.
- (void)evaluate:(NSString *)code identifier:(int)identifier;
/// CEF zoom level (factor = 1.2^level).
@property (nonatomic) double zoomLevel;
@property (nonatomic) BOOL muted;
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFinding;
- (void)showDevTools;
- (void)setFocus:(BOOL)focus;
- (void)close;
@end

NS_ASSUME_NONNULL_END
