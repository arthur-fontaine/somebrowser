import BrowserCore
import SwiftUI

public final class ToastsFeature: BrowserFeature {
    let context: FeatureContext
    let model: ToastModel

    public init(context: FeatureContext) {
        self.context = context
        model = ToastModel(settings: context.settings)
    }

    public func activate() {
        let model = self.model
        context.events.subscribe(ToastRequested.self) { model.show($0) }
        context.ui.contribute(.overlay, id: "toasts", order: 200) { window in ToastStack(window: window, model: model) }
    }
}

@Observable
final class ToastModel {
    struct Toast: Identifiable {
        let id = UUID()
        let request: ToastRequested
    }

    @ObservationIgnored let settings: SettingsStore
    private(set) var toasts: [Toast] = []
    static let maxVisible = 3

    init(settings: SettingsStore) { self.settings = settings }

    func show(_ request: ToastRequested) {
        let toast = Toast(request: request)
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            toasts.append(toast)
            if toasts.count > Self.maxVisible { toasts.removeFirst() }
        }
        let seconds = max(0.5, settings.double("toasts.duration")) + (request.action == nil ? 0 : 2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { toasts.removeAll { $0.id == id } }
    }

    func visible(in window: BrowserWindowState) -> [Toast] {
        toasts.filter { $0.request.windowID == nil || $0.request.windowID == window.id }
    }
}

struct ToastStack: View {
    let window: BrowserWindowState
    let model: ToastModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            ForEach(model.visible(in: window)) { toast in
                HStack(spacing: 8) {
                    if let icon = toast.request.systemImage { Image(systemName: icon).foregroundStyle(.secondary) }
                    Text(toast.request.message).font(.system(size: 13, weight: .medium))
                    if let title = toast.request.actionTitle, let action = toast.request.action {
                        Button(title) { action(); model.dismiss(toast.id) }
                            .buttonStyle(.borderless).font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(!model.visible(in: window).isEmpty)
    }
}
