import BrowserCore
import SwiftUI

/// Native settings window. Every declared setting gets a control automatically (grouped by feature);
/// features add richer panes through `UIRegistry.addSettingsPane`. Shortcuts are editable for every command.
struct SettingsRootView: View {
    @Environment(BrowserEnvironment.self) private var env
    @State private var selection: String?
    let initialPane: String?

    init(initialPane: String?) {
        self.initialPane = initialPane
        _selection = State(initialValue: initialPane ?? "general")
    }

    var body: some View {
        let runtime = env.runtime
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("General", systemImage: "gearshape").tag("general")
                    ForEach(runtime.ui.settingsPanes) { pane in
                        Label(pane.title, systemImage: pane.systemImage).tag(pane.id)
                    }
                    Label("Shortcuts", systemImage: "keyboard").tag("shortcuts")
                    Label("Features", systemImage: "puzzlepiece.extension").tag("features")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                Group {
                    switch selection {
                    case "shortcuts": ShortcutsPane()
                    case "features": FeaturesPane()
                    case "general", nil: GeneratedSettingsPane()
                    default:
                        if let pane = runtime.ui.settingsPanes.first(where: { $0.id == selection }) { pane.makeView() }
                    }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }
}

/// One section per feature with a control per declared setting.
struct GeneratedSettingsPane: View {
    @Environment(BrowserEnvironment.self) private var env

    var body: some View {
        let runtime = env.runtime
        Form {
            ForEach(runtime.manifests.filter { !$0.settings.isEmpty }, id: \.id) { m in
                Section(m.name) {
                    ForEach(m.settings) { d in SettingControl(descriptor: d, store: runtime.settings) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingControl: View {
    let descriptor: SettingDescriptor
    let store: SettingsStore

    var body: some View {
        let key = descriptor.key
        VStack(alignment: .leading, spacing: 2) {
            switch descriptor.kind {
            case .bool:
                Toggle(descriptor.title, isOn: Binding(get: { store.bool(key) }, set: { store.set(key, .bool($0)) }))
            case .choice:
                Picker(descriptor.title, selection: Binding(get: { store.string(key) }, set: { store.set(key, .string($0)) })) {
                    ForEach(descriptor.options, id: \.self) { Text(descriptor.title(ofOption: $0)).tag($0) }
                }
            case .int:
                Stepper(value: Binding(get: { store.int(key) }, set: { store.set(key, .int($0)) })) {
                    LabeledContent(descriptor.title, value: "\(store.int(key))")
                }
            case .double:
                LabeledContent(descriptor.title) {
                    TextField("", value: Binding(get: { store.double(key) }, set: { store.set(key, .double($0)) }), format: .number)
                        .frame(width: 90)
                }
            case .string:
                // The label above, the value across the row's width: long values (keyword lists) wrap, left-aligned.
                Text(descriptor.title)
                TextField(descriptor.title, text: Binding(get: { store.string(key) }, set: { store.set(key, .string($0)) }), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .multilineTextAlignment(.leading)
            }
            if let help = descriptor.description {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Every command with its shortcut; click to record a new one (Arc: everything is remappable).
struct ShortcutsPane: View {
    @Environment(BrowserEnvironment.self) private var env
    @State private var filter = ""
    @State private var recording: String?

    var body: some View {
        let commands = env.runtime.commands
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search commands", text: $filter).textFieldStyle(.roundedBorder)
            Form {
                ForEach(commands.descriptors.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }) { d in
                    LabeledContent(d.title) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(id: d.id, isRecording: recording == d.id) { recording = $0 ? d.id : nil }
                            if commands.userShortcuts[d.id] != nil {
                                Button("Reset") { commands.resetUserShortcut(for: d.id) }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Features in this build").font(.title2.bold())
            Text("Add or remove features in your fork with `./forkctl feature enable|disable <id>`. Engine: \(Brand.engineName).")
                .foregroundStyle(.secondary)
            Form {
                ForEach(env.runtime.manifests, id: \.id) { m in
                    LabeledContent {
                        Text(m.id).monospaced().foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            if !m.summary.isEmpty { Text(m.summary).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
