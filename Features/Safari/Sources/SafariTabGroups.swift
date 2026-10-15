import Foundation
import ObjectiveC

/// Tab Groups written by Safari's own code: WebBookmarks.framework (private, loaded at run time) on Safari's
/// SafariTabs.db. Rows written any other way lack what the sync agent needs, CloudKit records and per-attribute CRDT
/// generations in `sync_data`: adds are skipped ("Ignoring change lacking record") and deletes lose to the record's
/// other fields, so the item comes back (both seen live, 2026-10-15). The calls are Safari's own (macOS 27):
/// `WBTabGroupManager insertTabGroup:afterTabGroup:` / `updateTabsInTabGroup:completionHandler:` to add,
/// `WBTabCollection deleteTabs:` / `deleteTabGroup:` to remove (tombstones with the record's deletion generation).
@MainActor
final class SafariTabGroupWriter {
    private let database: URL

    /// nil if WebBookmarks or its classes aren't there (another macOS).
    init?(database: URL, createIfNeeded: Bool = false) {
        guard Self.frameworkLoaded, ["WBCollectionConfiguration", "WBTabCollection", "WBTabGroupManager", "WBMutableTabGroup", "WBMutableTab"]
            .allSatisfy({ NSClassFromString($0) != nil }) else { return nil }
        self.database = database
        if createIfNeeded, Session(database: database, create: true) == nil { return nil }
    }

    /// Makes the Tab Group `title` hold exactly `tabs` (their ids become the tabs' UUIDs), creating it if needed; true
    /// if anything was written.
    @discardableResult
    func mirror(title: String, tabs: [SafariBookmark]) async throws -> Bool {
        // A session per change: a manager loads the groups and their tabs from the database when it's made.
        guard let session = Session(database: database, create: false),
              let group = try await session.group(title: title, create: true),
              let groupID = group.value(forKey: "uuid") as? String else { return false }
        let currentIDs = try SafariStore.tabIDs(in: database, groupID: groupID)
        let removed = currentIDs.subtracting(tabs.map(\.id))
        let added = tabs.filter { !currentIDs.contains($0.id) }
        guard !removed.isEmpty || !added.isEmpty else { return false }
        let closing = ((group.value(forKey: "tabs") as? [NSObject]) ?? []).filter { removed.contains($0.value(forKey: "uuid") as? String ?? "") }
        if !added.isEmpty, let editable = group.mutableCopy() as? NSObject {
            // Out of the copy saved below, or saving it would keep them.
            for tab in closing { editable.perform(NSSelectorFromString("removeTab:"), with: tab) }
            editable.perform(NSSelectorFromString("appendTabs:"), with: added.compactMap(Self.makeTab) as NSArray)
            await session.save(editable)
        }
        if !closing.isEmpty { session.collection.perform(NSSelectorFromString("deleteTabs:"), with: closing as NSArray) }
        return true
    }

    /// Removes the Tab Group `title` and its tabs, as Safari deletes a group.
    func remove(title: String) async throws {
        guard let session = Session(database: database, create: false),
              let group = try await session.group(title: title, create: false) else { return }
        session.collection.perform(NSSelectorFromString("deleteTabGroup:"), with: group)
    }

    private static func makeTab(_ tab: SafariBookmark) -> NSObject? {
        make("WBMutableTab", "initWithUUID:title:url:") { object, sel in
            send((@convention(c) (Unmanaged<NSObject>, Selector, NSString, NSString, NSURL) -> Unmanaged<NSObject>?).self)(
                object, sel, tab.id as NSString, tab.title as NSString, tab.url as NSURL)
        }
    }

    /// WebBookmarks' collection and Tab Groups manager on one database.
    private struct Session {
        let collection: NSObject
        let manager: NSObject

        init?(database: URL, create: Bool) {
            guard let configuration = make("WBCollectionConfiguration", "initWithCollectionType:databasePath:readonly:createIfNeeded:", { object, sel in
                send((@convention(c) (Unmanaged<NSObject>, Selector, Int, NSString, ObjCBool, ObjCBool) -> Unmanaged<NSObject>?).self)(
                    object, sel, 1, database.path as NSString, false, ObjCBool(create))
            }) else { return nil }
            // Safari isn't told: it reads the rows on its next reload, and its agent uploads them with its next sync.
            send((@convention(c) (NSObject, Selector, ObjCBool) -> Void).self)(configuration, NSSelectorFromString("setSkipsExternalNotifications:"), true)
            guard let collection = make("WBTabCollection", "initWithConfiguration:openDatabase:", { object, sel in
                send((@convention(c) (Unmanaged<NSObject>, Selector, NSObject, ObjCBool) -> Unmanaged<NSObject>?).self)(object, sel, configuration, true)
            }), let manager = make("WBTabGroupManager", "initWithCollection:", { object, sel in
                send((@convention(c) (Unmanaged<NSObject>, Selector, NSObject) -> Unmanaged<NSObject>?).self)(object, sel, collection)
            }) else { return nil }
            self.collection = collection
            self.manager = manager
        }

        func group(title: String, create: Bool) async throws -> NSObject? {
            let groups = (manager.value(forKey: "allSyncedTabGroupsExceptRemoteUnnamedTabGroups") as? [NSObject]) ?? []
            if let found = groups.first(where: { $0.value(forKey: "title") as? String == title }) { return found }
            guard create, let group = make("WBMutableTabGroup", "initWithTitle:profileIdentifier:", { object, sel in
                send((@convention(c) (Unmanaged<NSObject>, Selector, NSString, NSString) -> Unmanaged<NSObject>?).self)(
                    object, sel, title as NSString, "DefaultProfile" as NSString)
            }), let uuid = group.value(forKey: "uuid") as? String else { return nil }
            manager.perform(NSSelectorFromString("insertTabGroup:afterTabGroup:"), with: group, with: nil)
            // The manager saves on the main run loop; edits need the group it has saved.
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(50))
                if let saved = manager.perform(NSSelectorFromString("tabGroupWithUUID:"), with: uuid)?.takeUnretainedValue() as? NSObject {
                    return saved
                }
            }
            throw SafariStore.StoreError.busy
        }

        func save(_ group: NSObject) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let completion: @convention(block) () -> Void = { done.resume() }
                send((@convention(c) (NSObject, Selector, NSObject, @convention(block) () -> Void) -> Void).self)(
                    manager, NSSelectorFromString("updateTabsInTabGroup:completionHandler:"), group, completion)
            }
        }
    }

    // MARK: Objective-C runtime

    private static let frameworkLoaded = dlopen("/System/Library/PrivateFrameworks/WebBookmarks.framework/WebBookmarks", RTLD_NOW) != nil
    private static let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")  // RTLD_DEFAULT

    private static func send<T>(_ type: T.Type) -> T { unsafeBitCast(msgSend, to: type) }

    /// `[[Class alloc] init…]`: `alloc` returns +1, `init…` consumes it and returns +1.
    private static func make(_ className: String, _ initializer: String,
                             _ initialize: (Unmanaged<NSObject>, Selector) -> Unmanaged<NSObject>?) -> NSObject? {
        guard let cls = NSClassFromString(className) else { return nil }
        let alloc = send((@convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>).self)(cls, NSSelectorFromString("alloc"))
        return initialize(alloc, NSSelectorFromString(initializer))?.takeRetainedValue()
    }
}
