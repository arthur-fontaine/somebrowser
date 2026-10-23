import AppKit
import BrowserCore
import SwiftUI

/// "Import from Another Browser": pick a browser profile, see what it holds, import.
struct ImportSheet: View {
    let model: ImportModel
    let window: BrowserWindowState
    let select: (SourceProfile) -> Void
    let allowAccess: (SourceProfile) -> Void
    let start: () -> Void
    let addExtension: (BrowserExtension) -> Void
    let close: () -> Void

    var body: some View {
        if window.flags.contains(ImportFeature.sheetFlag) {
            ZStack {
                Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture(perform: close)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Import from Another Browser").font(.title3.bold())
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    }
                    if let result = model.result { done(result) } else { picker }
                }
                .padding(20)
                .frame(width: 520)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .overlayKeyboardFocus("import", in: window)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder var picker: some View {
        if model.profiles.isEmpty {
            Text("No other browser found on this Mac.").foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.profiles) { profile in
                        SourceRow(profile: profile, selected: model.selected == profile).onTapGesture { select(profile) }
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider()
            if let locked = model.selected, locked.isLocked { access(locked) } else { contents }
        }
    }

    func access(_ profile: SourceProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS keeps \(profile.source.name)'s data from other apps until you allow it. In the window that opens, click Allow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Allow Access…") { allowAccess(profile) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder var contents: some View {
        let preview = model.preview
        Toggle(isOn: Binding(get: { model.includeBookmarks }, set: { model.includeBookmarks = $0 })) {
            label("Bookmarks", preview?.bookmarkCount, detail: "as a pinned folder in this space")
        }
        Toggle(isOn: Binding(get: { model.includeHistory }, set: { model.includeHistory = $0 })) {
            label("History", preview?.history.count, detail: nil)
        }
        Toggle(isOn: Binding(get: { model.includeExtensions }, set: { model.includeExtensions = $0 })) {
            label("Extensions", preview?.extensions.count, detail: "added from the Chrome Web Store")
        }
        if model.canImportCookies, model.selected?.isContributed == false {
            Toggle(isOn: Binding(get: { model.includeCookies }, set: { model.includeCookies = $0 })) {
                label("Cookies", preview?.cookies.count, detail: "stay signed in; macOS asks to unlock the browser's key")
            }
        }
        HStack {
            Spacer()
            Button(action: start) {
                if model.isImporting { ProgressView().controlSize(.small) } else { Text("Import") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(preview == nil || model.isImporting)
        }
    }

    func summary(_ result: ImportModel.Result) -> String {
        var parts = ["\(result.bookmarks.formatted()) bookmarks", "\(result.history.formatted()) history entries"]
        if result.cookies > 0 { parts.append("\(result.cookies.formatted()) cookies") }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last! + " imported."
    }

    func label(_ title: String, _ count: Int?, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(count.map { $0.formatted() } ?? "…").foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText())
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        }
        .animation(.default, value: count)
    }

    @ViewBuilder func done(_ result: ImportModel.Result) -> some View {
        Label(summary(result), systemImage: "checkmark.circle.fill")
            .symbolRenderingMode(.multicolor)
        if result.cookiesLocked {
            Text("Cookies weren't imported: the browser's key in the Keychain couldn't be read.").font(.callout).foregroundStyle(.secondary)
        }
        if !result.extensions.isEmpty {
            Text("Add your extensions:").font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(result.extensions) { ext in
                        HStack {
                            Text(ext.name).lineLimit(1)
                            Spacer()
                            if model.added.contains(ext.id) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            } else {
                                Button("Add") { addExtension(ext) }.controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
    }
}

struct SourceRow: View {
    let profile: SourceProfile
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(profile.source.bundleID)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.source.name)
                if profile.isLocked {
                    Text("Needs your permission").font(.caption).foregroundStyle(.secondary)
                } else if profile.name != "Default" {
                    Text(profile.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }

    static func icon(_ bundleID: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
    }
}
