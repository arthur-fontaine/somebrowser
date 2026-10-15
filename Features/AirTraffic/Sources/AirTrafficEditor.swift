import BrowserCore
import SwiftUI

/// The rules: a pattern and where its links go, in order (the first match wins).
struct AirTrafficEditor: View {
    @Bindable var model: AirTrafficModel
    let window: BrowserWindowState
    let spaces: [(id: UUID, name: String, icon: String)]
    let save: () -> Void
    let close: () -> Void

    var body: some View {
        if window.flags.contains(AirTrafficFeature.editorFlag) {
            ZStack {
                Color.black.opacity(0.15).contentShape(Rectangle()).onTapGesture(perform: done)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Air Traffic Control", systemImage: "airplane").font(.title3.bold())
                    Text("Links from other apps go where a rule says. The first matching rule wins.")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.rules.isEmpty {
                        Text("No rules yet").foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach($model.rules) { $rule in
                        HStack(spacing: 8) {
                            TextField("github.com or docs.google.com/document", text: $rule.pattern)
                                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Picker("", selection: $rule.destination) {
                                ForEach(spaces, id: \.id) { space in Label(space.name, systemImage: space.icon).tag(TrafficRule.Destination.space(space.id)) }
                                Divider()
                                Label("Mini Window", systemImage: "macwindow").tag(TrafficRule.Destination.miniWindow)
                                Label("Main Window", systemImage: "macwindow.on.rectangle").tag(TrafficRule.Destination.mainWindow)
                            }
                            .labelsHidden().frame(width: 170)
                            Button { model.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    HStack {
                        Button("Add Rule", systemImage: "plus") {
                            withAnimation(.spring(duration: 0.3)) {
                                model.rules.append(TrafficRule(pattern: "", destination: spaces.first.map { .space($0.id) } ?? .mainWindow))
                            }
                        }
                        Spacer()
                        Button("Done", action: done).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 560)
                .overlayKeyboardFocus("air-traffic.editor", in: window)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .onExitCommand(perform: done)
            }
        }
    }

    func done() {
        model.rules.removeAll { TrafficRule.normalized($0.pattern).isEmpty }
        save()
        close()
    }
}
