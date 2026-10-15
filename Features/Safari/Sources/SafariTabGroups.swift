import Foundation
import ObjectiveC

/// Tab Groups written by Safari's own code: WebBookmarks.framework (private, loaded at run time) on Safari's
/// SafariTabs.db. Rows written any other way lack what the sync agent needs (a CloudKit record and per-attribute CRDT
/// generations in `sync_data`): it skips them ("Ignoring change lacking record"). The calls are Safari's own:
/// `WBTabGroupManager insertTabGroup:afterTabGroup:` and `updateTabsInTabGroup:completionHandler:`, macOS 27.
@MainActor
final class SafariTabGroupWriter {
    private let manager: NSObject
    private let database: URL

    /// nil if WebBookmarks or its classes aren't there (another macOS).
    init?(database: URL, createIfNeeded: Bool = false) {
        guard Self.frameworkLoaded, let configuration = Self.make("WBCollectionConfiguration", "initWithCollectionType:databasePath:readonly:createIfNeeded:", { object, sel in
            Self.send((@convention(c) (Unmanaged<NSObject>, Selector, Int, NSString, ObjCBool, ObjCBool) -> Unmanaged<NSObject>?).self)(object, sel, 1, database.path as NSString, false, ObjCBool(createIfNeeded))
        }) else { return nil }
        // Safari isn't told: it reads the rows on its next reload, and its agent uploads them with its next sync.
        Self.send((@convention(c) (NSObject, Selector, ObjCBool) -> Void).self)(
            configuration, NSSelectorFromString("setSkipsExternalNotifications:"), true)
        guard let collection = Self.make("WBTabCollection", "initWithConfiguration:openDatabase:", { object, sel in
            Self.send((@convention(c) (Unmanaged<NSObject>, Selector, NSObject, ObjCBool) -> Unmanaged<NSObject>?).self)(object, sel, configuration, true)
        }), let manager = Self.make("WBTabGroupManager", "initWithCollection:", { object, sel in
            Self.send((@convention(c) (Unmanaged<NSObject>, Selector, NSObject) -> Unmanaged<NSObject>?).self)(object, sel, collection)
        }) else { return nil }
        self.manager = manager
        self.database = database
    }

    /// Makes the Tab Group `title` hold exactly `tabs` (their ids become the tabs' UUIDs), creating it if needed; true
    /// if anything was written.
    @discardableResult
    func mirror(title: String, tabs: [SafariBookmark]) async throws -> Bool {
        guard let group = try await group(title: title, create: true), let editable = group.mutableCopy() as? NSObject,
              let groupID = group.value(forKey: "uuid") as? String else { return false }
        // From the database: the manager loads a group's tabs lazily.
        let currentIDs = try SafariStore.tabIDs(in: database, groupID: groupID)
        let wanted = Set(tabs.map(\.id))
        let removed = currentIDs.subtracting(wanted)
        let added = tabs.filter { !currentIDs.contains($0.id) }
        guard !removed.isEmpty || !added.isEmpty else { return false }
        if !added.isEmpty {
            let newTabs = added.compactMap { tab in
                Self.make("WBMutableTab", "initWithUUID:title:url:") { object, sel in
                    Self.send((@convention(c) (Unmanaged<NSObject>, Selector, NSString, NSString, NSURL) -> Unmanaged<NSObject>?).self)(
                        object, sel, tab.id as NSString, tab.title as NSString, tab.url as NSURL)
                }
            }
            editable.perform(NSSelectorFromString("appendTabs:"), with: newTabs as NSArray)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let completion: @convention(block) () -> Void = { done.resume() }
                Self.send((@convention(c) (NSObject, Selector, NSObject, @convention(block) () -> Void) -> Void).self)(
                    manager, NSSelectorFromString("updateTabsInTabGroup:completionHandler:"), editable, completion)
            }
        }
        // Last: nothing saves this group's tabs after it.
        try SafariStore.removeTabGroupRows(in: database, externalIDs: Array(removed))
        return true
    }

    /// Removes the Tab Group `title` and its tabs.
    func remove(title: String) async throws {
        guard let group = try await group(title: title, create: false), let uuid = group.value(forKey: "uuid") as? String else { return }
        try SafariStore.removeTabGroupRows(in: database, externalIDs: [uuid])
    }

    private func group(title: String, create: Bool) async throws -> NSObject? {
        let groups = (manager.value(forKey: "allSyncedTabGroupsExceptRemoteUnnamedTabGroups") as? [NSObject]) ?? []
        if let found = groups.first(where: { $0.value(forKey: "title") as? String == title }) { return found }
        guard create, let group = Self.make("WBMutableTabGroup", "initWithTitle:profileIdentifier:", { object, sel in
            Self.send((@convention(c) (Unmanaged<NSObject>, Selector, NSString, NSString) -> Unmanaged<NSObject>?).self)(object, sel, title as NSString, "DefaultProfile" as NSString)
        }), let uuid = group.value(forKey: "uuid") as? String else { return nil }
        manager.perform(NSSelectorFromString("insertTabGroup:afterTabGroup:"), with: group, with: nil)
        // The manager saves on the main run loop; edits need the group it has saved.
        var saved: NSObject?
        try await settle { [manager] in
            saved = manager.perform(NSSelectorFromString("tabGroupWithUUID:"), with: uuid)?.takeUnretainedValue() as? NSObject
            return saved != nil
        }
        return saved
    }

    private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            if done() { return }
        }
        throw SafariStore.StoreError.busy
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
