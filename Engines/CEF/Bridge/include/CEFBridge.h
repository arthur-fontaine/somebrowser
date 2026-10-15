// Objective-C surface over CEF (Chrome style), consumed by the Swift engine.
// Each tab is a frameless Chrome-style CefWindow hosting one CefBrowserView (docs/decisions/0002).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass implementing CefAppProtocol (CEF requires it as NSPrincipalClass).
@interface BrowserCEFApplication : NSApplication
@end

/// Chrome's command ids (cef_command_ids.h) the browser runs itself.
static const int CEFChromeCommandSavePage = 35004;
static const int CEFChromeCommandConsole = 40005;
static const int CEFChromeCommandInspect = 40023;

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
/// The page sees this shortcut first (the browser gets it in `handleKeyEquivalent` only if the page doesn't use it).
- (BOOL)cefTab:(CEFTab *)tab prefersPageForKey:(NSEvent *)event;
- (BOOL)cefTab:(CEFTab *)tab shouldNavigateTo:(NSString *)url userGesture:(BOOL)gesture isRedirect:(BOOL)redirect;
/// Script to run in the main-frame document about to load at `url`, before the page's own scripts.
- (nullable NSString *)cefTab:(CEFTab *)tab documentStartScriptFor:(NSString *)url;
/// The page opened `newTab` (popup, target=_blank, ⌘-click, context menu "Open in New Tab").
- (void)cefTab:(CEFTab *)tab didOpen:(CEFTab *)newTab url:(nullable NSString *)url disposition:(CEFDisposition)disposition userGesture:(BOOL)gesture;
/// `window.__browser.post(name, body)`; `json` is `JSON.stringify(body)`. The sending frame is the browser
/// process's view of it (not page-supplied).
- (void)cefTab:(CEFTab *)tab message:(NSString *)name json:(NSString *)json mainFrame:(BOOL)mainFrame frameURL:(nullable NSString *)frameURL;
- (void)cefTabRequestsClose:(CEFTab *)tab;
- (void)cefTabDidCrash:(CEFTab *)tab;
/// Key down with ⌘/⌃ before the page sees it. Return YES when the browser consumed it (menu shortcut).
- (BOOL)cefTab:(CEFTab *)tab handleKeyEquivalent:(NSEvent *)event;
/// Kinds: camera, microphone, screenCapture, location, notifications, clipboard, midi.
- (void)cefTab:(CEFTab *)tab requestsPermissions:(NSArray<NSString *> *)kinds origin:(NSString *)origin
         reply:(void (^)(BOOL granted))reply;
@end

@protocol CEFRuntimeDelegate <NSObject>
/// Called on the IO thread for every request: must be fast and thread-safe. nil continues, an empty string
/// blocks, any other string replaces the URL (e.g. tracking parameters removed).
- (nullable NSString *)cefFilterRequest:(NSString *)url firstParty:(nullable NSString *)firstParty type:(NSString *)type;
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
/// Host Chrome's toolbar invisibly in every page (extension actions, popups). Set before creating tabs.
@property (nonatomic) BOOL extensionToolbar;
/// Virtual width of that toolbar: room for the pinned actions before Chrome overflows them into its menu.
@property (nonatomic) int extensionToolbarWidth;
/// Profile preferences applied when the default request context is initialized (bool, number or string values).
@property (copy) NSDictionary<NSString *, id> *profilePreferences;
/// Set once the profile exists (preferences given before are applied then).
@property BOOL contextReady;
/// Sets a profile preference now, or when the profile is created (main thread).
- (void)setProfilePreference:(NSString *)name value:(id)value;
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
/// `isPrivate`: an off-the-record profile shared by private tabs (nothing written to disk).
- (instancetype)initWithURL:(nullable NSString *)url delegate:(nullable id<CEFTabDelegate>)delegate private:(BOOL)isPrivate;
@property (readonly) BOOL isPrivate;
@property (weak, nullable) id<CEFTabDelegate> delegate;
/// The page's own frameless window (exists right after init; the browser itself is created asynchronously).
@property (readonly, nullable) NSWindow *window;
@property (readonly) BOOL isReady;
@property (readonly, nullable) NSString *currentURL;
- (void)loadURL:(NSString *)url;
/// Loads `url` but answers it with this response instead of the network (the page keeps `url`'s origin).
- (void)loadURL:(NSString *)url simulatingStatus:(int)status statusText:(NSString *)statusText
          headers:(NSDictionary<NSString *, NSString *> *)headers body:(NSData *)body;
- (void)goBack;
- (void)goForward;
- (void)print;
/// The back/forward list as `{url, title}` entries, oldest first; `currentIndex` receives the current entry's index
/// (-1 while the browser doesn't exist yet).
- (NSArray<NSDictionary<NSString *, NSString *> *> *)navigationEntriesWithCurrentIndex:(NSInteger *)currentIndex;
- (void)reloadIgnoringCache:(BOOL)ignoreCache;
- (void)stopLoad;
- (void)executeJavaScript:(NSString *)code;
/// Evaluates in the main frame's context through the renderer (not subject to page CSP); the result arrives
/// as message `__eval` with JSON `{id, ok, value | error}`.
- (void)evaluate:(NSString *)code identifier:(int)identifier;
/// Opens Chrome's extensions menu, anchored to the hidden toolbar. NO without a toolbar.
- (BOOL)showExtensionsMenu;
/// Runs an extension's action as a toolbar click would (popup, onClicked, activeTab): its pinned button, else
/// its entry in the extensions menu. `name` is the name Chrome displays.
- (void)runExtensionActionNamed:(NSString *)name completion:(void (^)(BOOL ran))completion;
/// CEF zoom level (factor = 1.2^level).
@property (nonatomic) double zoomLevel;
@property (nonatomic) BOOL muted;
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFinding;
- (void)showDevTools;
/// Runs one of Chrome's own commands (the page's other Chrome commands stay off: our menus own them).
- (void)runChromeCommand:(int)commandID;
- (void)setFocus:(BOOL)focus;
- (void)close;
@end

NS_ASSUME_NONNULL_END
