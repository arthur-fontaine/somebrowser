import BrowserCore
import SwiftUI

/// Native settings window. Every declared setting gets a control automatically, on the page its feature names
/// (`SettingsPageModel`); features add richer panes through `UIRegistry.addSettingsPane`. Shortcuts are editable for
/// every command.
struct SettingsRootView: View {
    @Environment(BrowserEnvironment.self) private var env
    @State private var selection: String?
    @State private var query = ""
    @State private var back: [String] = []
    @State private var forward: [String] = []
    /// Set while going back or forward, so that move isn't recorded as a new one.
    @State private var traversing = false

    init(initialPane: String?) {
        _selection = State(initialValue: initialPane ?? "general")
    }

    var body: some View {
        let runtime = env.runtime
        let pages = SettingsPageModel.build(manifests: runtime.manifests, panes: runtime.ui.settingsPanes)
        let all = pages.main + pages.advanced
        let page = all.first { $0.id == selection } ?? all[0]
        NavigationSplitView {
            List(selection: $selection) {
                Section { ForEach(pages.main.filter { matches($0) }) { SidebarRow(page: $0) } }
                let advanced = pages.advanced.filter { matches($0) }
                if !advanced.isEmpty {
                    Section("Advanced") { ForEach(advanced) { SidebarRow(page: $0) } }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPageView(page: page, query: query)
                .id(page.id)
                .navigationTitle(page.title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button("Back", systemImage: "chevron.left") { go(from: &back, to: &forward) }.disabled(back.isEmpty)
                            Button("Forward", systemImage: "chevron.right") { go(from: &forward, to: &back) }.disabled(forward.isEmpty)
                        }
                        .controlGroupStyle(.navigation)
                    }
                }
        }
        .onChange(of: selection) { old, _ in
            if traversing { traversing = false; return }
            if let old { back.append(old) }
            forward.removeAll()
        }
    }

    private func go(from stack: inout [String], to other: inout [String]) {
        guard let target = stack.popLast() else { return }
        if let selection { other.append(selection) }
        traversing = true
        selection = target
    }

    private func matches(_ page: SettingsPageModel) -> Bool {
        guard !query.isEmpty else { return true }
        if page.title.localizedCaseInsensitiveContains(query) || !page.sections(matching: query).isEmpty { return true }
        if case .keyboard = page.content { return env.runtime.commands.descriptors.contains { SettingsPageModel.matches($0, query) } }
        return false
    }
}

/// A System Settings row: the page's symbol, white on its color.
struct SidebarRow: View {
    let page: SettingsPageModel

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(page.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .tag(page.id)
    }
}

struct SettingsPageView: View {
    @Environment(BrowserEnvironment.self) private var env
    let page: SettingsPageModel
    let query: String

    var body: some View {
        let store = env.runtime.settings
        switch page.content {
        case .pane(let pane):
            ScrollView { pane.makeView().padding(24).frame(maxWidth: .infinity, alignment: .leading) }
        case .features:
            FeaturesPane()
        case .settings, .keyboard:
            Form {
                ForEach(page.sections(matching: query)) { section in
                    Section(section.title) {
                        ForEach(section.settings) { SettingControl(descriptor: $0, store: store) }
                    }
                }
                if case .keyboard = page.content { ShortcutSections(query: page.title.localizedCaseInsensitiveContains(query) ? "" : query) }
            }
            .formStyle(.grouped)
        }
    }
}

/// A row's label: the title, and under it the description in secondary text (grouped forms lay the second `Text` out
/// that way).
struct SettingLabel: View {
    let descriptor: SettingDescriptor

    var body: some View {
        Text(descriptor.title)
        if let help = descriptor.description { Text(help) }
    }
}

struct SettingControl: View {
    let descriptor: SettingDescriptor
    let store: SettingsStore

    var body: some View {
        let key = descriptor.key
        switch descriptor.kind {
        case .bool:
            Toggle(isOn: Binding(get: { store.bool(key) }, set: { store.set(key, .bool($0)) })) { SettingLabel(descriptor: descriptor) }
        case .choice:
            Picker(selection: Binding(get: { store.string(key) }, set: { store.set(key, .string($0)) })) {
                ForEach(descriptor.options, id: \.self) { Text(descriptor.title(ofOption: $0)).tag($0) }
            } label: {
                SettingLabel(descriptor: descriptor)
            }
        case .int:
            let value = Binding(get: { store.int(key) }, set: { store.set(key, .int(max(0, $0))) })
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                    if let unit = descriptor.unit { Text(unit).foregroundStyle(.secondary) }
                    // Big values (widths in points, days of history) move in tens.
                    Stepper("", value: value, step: abs(descriptor.defaultValue.intValue ?? 0) >= 100 ? 10 : 1).labelsHidden()
                }
            } label: {
                SettingLabel(descriptor: descriptor)
            }
        case .double:
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", value: Binding(get: { store.double(key) }, set: { store.set(key, .double($0)) }), format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                    if let unit = descriptor.unit { Text(unit).foregroundStyle(.secondary) }
                }
            } label: {
                SettingLabel(descriptor: descriptor)
            }
        case .string:
            if let editor = descriptor.editor {
                ListSettingEditor(descriptor: descriptor, editor: editor, store: store)
            } else {
                TextField(text: Binding(get: { store.string(key) }, set: { store.set(key, .string($0)) })) { SettingLabel(descriptor: descriptor) }
            }
        }
    }
}

/// A comma-separated string edited one item per row (`pairs`: `key=value` items, as two fields).
struct ListSettingEditor: View {
    let descriptor: SettingDescriptor
    let editor: SettingEditor
    let store: SettingsStore
    /// Rows being edited, an empty new one included (the stored string leaves empty items out).
    @State private var items: [Item] = []

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    var body: some View {
        LabeledContent {
            Button("Add", systemImage: "plus") { items.append(Item()) }.labelStyle(.iconOnly)
        } label: {
            SettingLabel(descriptor: descriptor)
        }
        .onAppear { items = Self.items(of: store.string(descriptor.key), editor: editor) }
        ForEach($items) { $item in
            HStack(spacing: 8) {
                if editor == .pairs {
                    TextField("Keyword", text: $item.key).frame(width: 90)
                    TextField("URL with %s", text: $item.value)
                } else {
                    TextField("Item", text: $item.value)
                }
                Button("Remove", systemImage: "minus.circle.fill") { items.removeAll { $0.id == item.id } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
        .onChange(of: items) { _, items in store.set(descriptor.key, .string(Self.string(of: items, editor: editor))) }
    }

    static func items(of string: String, editor: SettingEditor) -> [Item] {
        string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { part in
            guard editor == .pairs, let eq = part.firstIndex(of: "=") else { return Item(value: part) }
            return Item(key: String(part[..<eq]), value: String(part[part.index(after: eq)...]))
        }
    }

    static func string(of items: [Item], editor: SettingEditor) -> String {
        items.compactMap { item in
            let key = item.key.trimmingCharacters(in: .whitespaces), value = item.value.trimmingCharacters(in: .whitespaces)
            if editor == .pairs { return key.isEmpty || value.isEmpty ? nil : "\(key)=\(value)" }
            return value.isEmpty ? nil : value
        }.joined(separator: ",")
    }
}

/// Every command with its shortcut, a section per menu; click to record a new one (Arc: everything is remappable).
struct ShortcutSections: View {
    @Environment(BrowserEnvironment.self) private var env
    let query: String
    @State private var recording: String?

    static let menus = ["File", "Edit", "View", "History", "Tabs", "Window", "Help"]

    var body: some View {
        let commands = env.runtime.commands
        let matching = commands.descriptors.filter { SettingsPageModel.matches($0, query) }
        let groups = Dictionary(grouping: matching) { $0.menu ?? "" }
        let order = Self.menus + groups.keys.filter { !Self.menus.contains($0) && !$0.isEmpty }.sorted() + [""]
        ForEach(order.filter { groups[$0] != nil }, id: \.self) { menu in
            Section(menu.isEmpty ? "Other Commands" : "\(menu) Menu") {
                ForEach(groups[menu] ?? []) { d in
                    LabeledContent(d.title) {
                        HStack(spacing: 6) {
                            if commands.userShortcuts[d.id] != nil {
                                Button("Reset") { commands.resetUserShortcut(for: d.id) }.buttonStyle(.link)
                            }
                            ShortcutRecorder(id: d.id, isRecording: recording == d.id) { recording = $0 ? d.id : nil }
                        }
                    }
                }
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Environment(BrowserEnvironment.self) private var env
    let id: String
    let isRecording: Bool
    let setRecording: (Bool) -> Void
    @State private var monitor: Any?

    var body: some View {
        let shortcut = env.runtime.commands.shortcut(for: id)
        Button(isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "—")) {
            isRecording ? stop() : start()
        }
        .monospaced()
        .frame(minWidth: 110)
        .onDisappear { stop() }
    }

    private func start() {
        setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // esc cancels
            if event.keyCode == 51 { env.runtime.commands.setUserShortcut(nil, for: id); stop(); return nil }
            if let s = Self.shortcut(from: event) {
                env.runtime.commands.setUserShortcut(s, for: id)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setRecording(false)
    }

    static func shortcut(from event: NSEvent) -> KeyShortcut? {
        var mods: KeyShortcut.Modifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        let named: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 48: "tab", 36: "return", 49: "space", 51: "delete"]
        let key = named[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !key.isEmpty, !mods.isEmpty || key.hasPrefix("f") else { return nil }
        return KeyShortcut(key: key, modifiers: mods)
    }
}

struct FeaturesPane: View {
    @Environment(BrowserEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                ForEach(env.runtime.manifests, id: \.id) { m in
                    LabeledContent {
                        Text(m.id).monospaced().foregroundStyle(.secondary)
                    } label: {
                        Text(m.name)
                        if !m.summary.isEmpty { Text(m.summary) }
                    }
                }
            } header: {
                Text("\(env.runtime.manifests.count) features · \(Brand.engineName)")
            } footer: {
                Text("Add or remove features in your fork with `./forkctl feature enable|disable <id>`.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
