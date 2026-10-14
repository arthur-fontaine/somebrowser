import AppKit
import BrowserCore
import SwiftUI

public final class SpacesFeature: BrowserFeature {
    let context: FeatureContext
    var runtime: BrowserRuntime { context.runtime }
    static let editFlag = "spaces.editing"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        let c = context.commands
        c.handle("spaces.next") { [weak self] inv in self?.step(1, inv.window) }
        c.handle("spaces.previous") { [weak self] inv in self?.step(-1, inv.window) }
        for i in 1...9 {
            c.handle("spaces.select-\(i)", isEnabled: { [weak self] _ in (self?.context.tabs.spaces.count ?? 0) >= i }) { [weak self] inv in
                self?.select(index: i - 1, inv.window)
            }
        }
        c.handle("spaces.new") { [weak self] inv in
            guard let self, let w = inv.window else { return }
            let space = self.createSpace()
            self.runtime.switchSpace(space.id, in: w)
            w.flags.insert(Self.editFlag)
        }
        c.handle("spaces.edit") { inv in inv.window?.flags.insert(Self.editFlag) }
        c.handle("spaces.delete", isEnabled: { [weak self] _ in (self?.context.tabs.spaces.count ?? 0) > 1 }) { [weak self] inv in
            guard let self, let w = inv.window else { return }
            self.delete(w.spaceID, from: w)
        }

        let runtime = self.runtime
        context.ui.contribute("background", id: "spaces.background") { window in SpaceBackground(window: window, runtime: runtime) }
        context.ui.contribute("sidebar.footer", id: "spaces.switcher", order: 50) { window in SpaceSwitcher(window: window, runtime: runtime) }
        context.ui.contribute(.overlay, id: "spaces.editor", order: 80) { window in SpaceEditorOverlay(window: window, runtime: runtime) }
    }

    func step(_ delta: Int, _ window: BrowserWindowState?) {
        guard let w = window else { return }
        let spaces = context.tabs.spaces
        guard let i = spaces.firstIndex(where: { $0.id == w.spaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { NSSound.beep(); return }
        runtime.switchSpace(spaces[j].id, in: w)
    }

    func select(index: Int, _ window: BrowserWindowState?) {
        guard let w = window, context.tabs.spaces.indices.contains(index) else { return }
        runtime.switchSpace(context.tabs.spaces[index].id, in: w)
    }

    @discardableResult
    func createSpace() -> Space {
        let icons = ["briefcase.fill", "house.fill", "star.fill", "leaf.fill", "bolt.fill", "book.fill", "gamecontroller.fill"]
        let n = context.tabs.spaces.count
        return context.tabs.addSpace(name: "Space \(n + 1)", icon: icons[n % icons.count])
    }

    func delete(_ id: UUID, from window: BrowserWindowState) {
        let spaces = context.tabs.spaces
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let fallback = spaces[i == 0 ? 1 : i - 1]
        for w in runtime.windows where w.spaceID == id { runtime.switchSpace(fallback.id, in: w) }
        context.tabs.removeSpace(id)
    }
}

// MARK: Background

/// Arc-style tinted window: the space's gradient under a material, crossfading on switch.
struct SpaceBackground: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        let space = runtime.tabs.space(window.spaceID)
        let themed = runtime.settings.bool("spaces.themedWindow")
        let intensity = max(0, min(1, runtime.settings.double("spaces.themeIntensity")))
        ZStack {
            VisualEffect(material: .underWindowBackground)
            if themed, let theme = space?.theme {
                LinearGradient(colors: theme.colors.compactMap(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(intensity * (window.isKeyWindow ? 1 : 0.7))
                    .id(space?.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: space?.id)
        .ignoresSafeArea()
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: Switcher

struct SpaceSwitcher: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        let spaces = runtime.tabs.spaces
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Array(spaces.enumerated()), id: \.element.id) { i, space in
                SpaceDot(space: space, index: i, selected: space.id == window.spaceID) {
                    runtime.switchSpace(space.id, in: window)
                }
                .contextMenu {
                    Button("Edit Space…") {
                        runtime.switchSpace(space.id, in: window)
                        window.flags.insert(SpacesFeature.editFlag)
                    }
                    if spaces.count > 1 {
                        Button("Delete Space") { try? runtime.commands.run("spaces.delete", window: window) }
                    }
                }
            }
            Button { try? runtime.commands.run("spaces.new", window: window) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help("New Space")
            Spacer(minLength: 0)
        }
    }
}

struct SpaceDot: View {
    let space: Space
    let index: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if selected || hovering {
                    SpaceGlyph(icon: space.icon).frame(width: 12, height: 12)
                } else {
                    Circle().frame(width: 6, height: 6)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(selected ? 0.12 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .tertiary)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: selected)
    }
}

struct SpaceGlyph: View {
    let icon: String
    var body: some View {
        if icon.count == 1, icon.unicodeScalars.first.map({ $0.properties.isEmoji && $0.value > 0xFF }) == true {
            Text(icon).font(.system(size: 11))
        } else {
            Image(systemName: icon).resizable().scaledToFit()
        }
    }
}

// MARK: Editor

struct SpaceEditorOverlay: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        if window.flags.contains(SpacesFeature.editFlag), let space = runtime.tabs.space(window.spaceID) {
            ZStack {
                Color.black.opacity(0.15).contentShape(Rectangle()).onTapGesture { window.flags.remove(SpacesFeature.editFlag) }
                SpaceEditor(space: space, store: runtime.tabs) { window.flags.remove(SpacesFeature.editFlag) }
                    .overlayKeyboardFocus("spaces.editor", in: window)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }
}

struct SpaceEditor: View {
    let space: Space
    let store: TabStore
    let done: () -> Void
    @State private var name = ""
    static let icons = ["person.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "leaf.fill", "bolt.fill",
                        "book.fill", "graduationcap.fill", "gamecontroller.fill", "music.note", "camera.fill", "cart.fill", "airplane"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Space").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 7), spacing: 8) {
                ForEach(Self.icons, id: \.self) { icon in
                    Button { store.updateSpace(space.id) { $0.icon = icon } } label: {
                        Image(systemName: icon).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(space.icon == icon ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(SpaceTheme.defaults.enumerated()), id: \.offset) { _, theme in
                    Button { store.updateSpace(space.id) { $0.theme = theme } } label: {
                        Circle()
                            .fill(LinearGradient(colors: theme.colors.compactMap(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.white, lineWidth: space.theme == theme ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear { name = space.name }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { store.updateSpace(space.id) { $0.name = trimmed } }
        done()
    }
}
