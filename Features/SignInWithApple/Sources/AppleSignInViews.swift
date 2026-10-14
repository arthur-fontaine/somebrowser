import AppKit
import BrowserCore
import SwiftUI

/// The page dims and blurs while signing in.
struct AppleSignInBackdrop: View {
    let model: AppleSignInModel
    let window: BrowserWindowState

    var body: some View {
        ZStack {
            if model.phase != .idle {
                BehindWindowBlur().overlay(Color.black.opacity(0.18)).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.phase == .idle)
        .allowsHitTesting(model.phase != .idle)
    }
}

/// The system's Sign in with Apple sheet, hosted in the window, with progress and a brief "Done".
struct AppleSignInSheet: View {
    let model: AppleSignInModel
    let window: BrowserWindowState
    let cancel: () -> Void

    var body: some View {
        ZStack {
            switch model.phase {
            case .idle:
                EmptyView()
            case .signingIn:
                card { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Signing in…") }.padding(20) }
            case .sheet:
                if let sheet = model.sheet {
                    card { HostedController(controller: sheet).frame(width: max(sheet.preferredContentSize.width, 360),
                                                                      height: max(sheet.preferredContentSize.height, 300)) }
                        .overlayKeyboardFocus("apple-signin", in: window)
                }
            case .done:
                card {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold)).symbolRenderingMode(.multicolor).padding(20)
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.phase)
        .onExitCommand { if model.phase != .idle { cancel() } }
    }

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
    }
}

struct HostedController: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

/// Blurs what is behind the overlay window (the page lives in its own window on Chromium).
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .fullScreenUI
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
