import BrowserCore
import SwiftUI

/// In site controls: the site's Boost, its switch and the editor.
struct BoostRow: View {
    let model: BoostsModel
    let site: String?
    let boost: (String) -> Boost?
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        if let site {
            let _ = model.revision
            let current = boost(site)
            HStack {
                Image(systemName: current?.enabled == true ? "paintbrush.fill" : "paintbrush").contentTransition(.symbolEffect(.replace)).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Boost")
                    Text(current.map { $0.enabled ? summary($0) : "Off" } ?? "Make this site yours").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(current == nil ? "Create…" : "Edit…", action: edit).controlSize(.small)
                if current != nil {
                    Toggle("", isOn: Binding(get: { current?.enabled == true }, set: { _ in toggle() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
    }

    func summary(_ b: Boost) -> String {
        [b.css.isEmpty ? nil : "CSS", b.js.isEmpty ? nil : "JavaScript", b.zapped.isEmpty ? nil : "\(b.zapped.count) zapped"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Boost editor: CSS, JavaScript, zapped elements.
struct BoostEditor: View {
    @Bindable var model: BoostsModel
    let window: BrowserWindowState
    let save: () -> Void
    let zap: () -> Void
    let close: () -> Void

    var body: some View {
        if window.flags.contains(BoostsFeature.editorFlag) {
            ZStack {
                Color.black.opacity(0.15).contentShape(Rectangle()).onTapGesture(perform: close)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Boost \(model.site ?? "")", systemImage: "paintbrush.fill").font(.title3.bold())
                        Spacer()
                        Toggle("On", isOn: $model.draft.enabled).toggleStyle(.switch).controlSize(.small)
                    }
                    section("CSS", text: $model.draft.css, placeholder: "body { font-family: ui-serif; }")
                    section("JavaScript", text: $model.draft.js, placeholder: "document.title = 'Mine'  // runs once the page is parsed")
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Zapped elements").font(.headline)
                            if model.draft.zapped.isEmpty {
                                Text("None").foregroundStyle(.secondary).font(.callout)
                            }
                            ForEach(model.draft.zapped, id: \.self) { selector in
                                HStack {
                                    Text(selector).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Button { model.draft.zapped.removeAll { $0 == selector } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button("Zap Elements…", systemImage: "bolt", action: zap)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).lineLimit(3)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                        Button("Save", action: save).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 600)
                .overlayKeyboardFocus("boosts.editor", in: window)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    func section(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder).font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
