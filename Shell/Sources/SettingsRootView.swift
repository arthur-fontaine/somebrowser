import BrowserCore
import SwiftUI

/// Native settings window. Every declared setting gets a control automatically, on the page its feature names
/// (`SettingsPageModel`); features add richer panes through `UIRegistry.addSettingsPane`. Shortcuts are editable for
/// every command.
struct SettingsRootView: View {
    @Environment(BrowserEnvironment.self) private var env
    @State private var selection: String?
    @State private var query = ""
    @State private var highlighted: String?
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
            Group {
                if query.isEmpty {
                    List(selection: $selection) {
                        Section("Browser") { ForEach(pages.main) { SidebarRow(page: $0, isSelected: $0.id == selection) } }
                        Section("Advanced") { ForEach(pages.advanced) { SidebarRow(page: $0, isSelected: $0.id == selection) } }
                    }
                } else {
                    results(SettingsPageModel.results(for: query, in: all, commands: runtime.commands.descriptors))
                }
            }
            .listStyle(.sidebar)
            // Pinned before mounting: the implicit sidebar style paints icons a frame late.
            .labelStyle(.titleAndIcon)
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            // The column width alone isn't kept in this window.
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPageView(page: page)
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

    @ViewBuilder private func results(_ results: [SettingsPageModel.SearchResult]) -> some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Its own `List`: result ids and page ids never share a selection.
            List(selection: $highlighted) {
                Section("Results") {
                    ForEach(results) { result in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).lineLimit(1)
                                Text(result.breadcrumb).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            SettingsIcon(systemImage: result.systemImage, tint: .accentColor)
                        }
                        .tag(result.id)
                    }
                }
            }
            // Moving through the results moves the page along, as System Settings does.
            .onChange(of: highlighted) { _, id in
                if let result = results.first(where: { $0.id == id }) { selection = result.pageID }
            }
        }
    }

    private func go(from stack: inout [String], to other: inout [String]) {
        guard let target = stack.popLast() else { return }
        if let selection { other.append(selection) }
        traversing = true
        selection = target
    }
}

/// A symbol on a pale tile of its own tint.
struct SettingsIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        // Sized here: a sidebar scales a label's icon up to its own size.
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundStyle(tint)
            .padding(4)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct SidebarRow: View {
    @Environment(\.appearsActive) private var appearsActive
    let page: SettingsPageModel
    let isSelected: Bool

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            // On the selected row's accent the tile goes white; in a background window everything greys.
            SettingsIcon(systemImage: page.systemImage, tint: appearsActive ? (isSelected ? .primary : .accentColor) : .secondary)
        }
        .tag(page.id)
    }
}

struct SettingsPageView: View {
    @Environment(BrowserEnvironment.self) private var env
    let page: SettingsPageModel

    var body: some View {
        let store = env.runtime.settings
        switch page.content {
        case .pane(let pane):
            ScrollView { pane.makeView().padding(24).frame(maxWidth: .infinity, alignment: .leading) }
        case .features:
            FeaturesPane()
        case .settings, .keyboard:
            Form {
                ForEach(page.sections) { section in
                    Section(section.title) {
                        ForEach(section.settings) { SettingControl(descriptor: $0, store: store) }
                    }
                }
                if case .keyboard = page.content { ShortcutSections() }
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

/// A list row: a title, maybe a subtitle under it, and controls at the end. Not `LabeledContent`, whose selectable
/// text takes the clicks a recorder needs.
struct SettingsListRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(subtitle)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
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

/// A comma-separated string as a list: a row per item with edit and delete, items added and edited in a sheet
/// (`pairs`: `key=value` items, the value under the key).
struct ListSettingEditor: View {
    let descriptor: SettingDescriptor
    let editor: SettingEditor
    let store: SettingsStore
    @State private var draft: Draft?

    struct Item: Equatable {
        var key = ""
        var value = ""
    }

    /// The item being added (`index` nil) or edited.
    struct Draft: Identifiable {
        let id = UUID()
        var index: Int?
        var item: Item
    }

    var body: some View {
        let items = Self.items(of: store.string(descriptor.key), editor: editor)
        // Styled here: forms only style a control's label as title and subtitle.
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.title)
            if let help = descriptor.description { Text(help).font(.subheadline).foregroundStyle(.secondary) }
        }
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            SettingsListRow(title: editor == .pairs ? item.key : item.value, subtitle: editor == .pairs ? item.value : nil) {
                Button { draft = Draft(index: index, item: item) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Edit")
                Button { save(items.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain).help("Delete")
            }
        }
        Button(editor == .pairs ? "Add Keyword…" : "Add…") { draft = Draft(item: Item()) }
            .sheet(item: $draft) { draft in
                ListItemSheet(editor: editor, draft: draft) { item in
                    var items = items
                    if let i = draft.index { items[i] = item } else { items.append(item) }
                    save(items)
                }
            }
    }

    private func save(_ items: [Item]) { store.set(descriptor.key, .string(Self.string(of: items, editor: editor))) }

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

struct ListItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let editor: SettingEditor
    let save: (ListSettingEditor.Item) -> Void
    @State private var item: ListSettingEditor.Item
    private let isNew: Bool

    init(editor: SettingEditor, draft: ListSettingEditor.Draft, save: @escaping (ListSettingEditor.Item) -> Void) {
        self.editor = editor
        self.save = save
        _item = State(initialValue: draft.item)
        isNew = draft.index == nil
    }

    var body: some View {
        let fields = editor == .pairs ? [item.key, item.value] : [item.value]
        // The list is stored comma-separated.
        let hasComma = fields.contains { $0.contains(",") }
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add" : "Edit").font(.headline)
            Form {
                if editor == .pairs {
                    TextField("Keyword", text: $item.key, prompt: Text("yt"))
                    TextField("URL", text: $item.value, prompt: Text("https://www.youtube.com/results?search_query=%s"))
                } else {
                    TextField("Value", text: $item.value)
                }
            }
            if hasComma { Text("Commas aren't allowed.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save(item); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasComma || fields.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Every command with its shortcut, a section per menu; click to record a new one (Arc: everything is remappable).
struct ShortcutSections: View {
    @Environment(BrowserEnvironment.self) private var env
    @State private var recording: String?

    static let menus = ["File", "Edit", "View", "History", "Tabs", "Window", "Help"]

    var body: some View {
        let commands = env.runtime.commands
        let groups = Dictionary(grouping: commands.descriptors) { $0.menu ?? "" }
        let order = Self.menus + groups.keys.filter { !Self.menus.contains($0) && !$0.isEmpty }.sorted() + [""]
        ForEach(order.filter { groups[$0] != nil }, id: \.self) { menu in
            Section(menu.isEmpty ? "Other Commands" : "\(menu) Menu") {
                ForEach(groups[menu] ?? []) { d in
                    SettingsListRow(title: d.title) {
                        if commands.userShortcuts[d.id] != nil {
                            Button { commands.resetUserShortcut(for: d.id) } label: {
                                Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Restore the default shortcut")
                        }
                        ShortcutRecorder(id: d.id, isRecording: recording == d.id) { recording = $0 ? d.id : nil }
                    }
                }
            }
        }
    }
}

/// A shortcut well: each key on its own cap, "Record Shortcut" when there's none; click, then type the new one (esc
/// cancels, delete clears).
struct ShortcutRecorder: View {
    @Environment(BrowserEnvironment.self) private var env
    let id: String
    let isRecording: Bool
    let setRecording: (Bool) -> Void
    @State private var monitor: Any?
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .padding(.horizontal, 7)
            // One width whatever the shortcut, so the column lines up.
            .frame(width: 120, height: 24)
            .background(shape.fill(Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isRecording ? 1.5 : 1))
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { isRecording ? stop() : start() }
            .onHover { hovered = $0 }
            .onDisappear { stop() }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder private var content: some View {
        if isRecording {
            Text("Listening…").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else if let shortcut = env.runtime.commands.shortcut(for: id) {
            HStack(spacing: 4) {
                ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                }
            }
            .frame(maxWidth: .infinity)
            // Over the caps, not beside them, so it costs them no width.
            .overlay(alignment: .trailing) {
                Button { env.runtime.commands.setUserShortcut(nil, for: id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove the shortcut")
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
        } else {
            Text("Record Shortcut")
                .font(.caption)
                .foregroundStyle(hovered ? .secondary : .tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
