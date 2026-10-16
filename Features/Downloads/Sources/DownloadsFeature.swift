import AppKit
import BrowserCore
import SwiftUI

public final class DownloadsFeature: BrowserFeature {
    let context: FeatureContext
    let model: DownloadsModel
    static let panelFlag = "downloads.panel"

    public init(context: FeatureContext) {
        self.context = context
        model = DownloadsModel()
    }

    public func activate() {
        let model = self.model
        let settings = context.settings
        context.hooks.downloadDestination = { source, name in
            if settings.bool("downloads.askWhereToSave") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.directoryURL = DownloadsModel.downloadsFolder
                if panel.runModal() == .OK, let url = panel.url { return url }
            }
            return DownloadsModel.uniqueDestination(for: name, in: DownloadsModel.downloadsFolder)
        }
        context.hooks.observeDownloads { [weak self] event in self?.handle(event) }

        context.commands.handle("downloads.show") { inv in inv.window?.toggle(flag: Self.panelFlag) }
        context.commands.handle("downloads.open-folder") { _ in NSWorkspace.shared.open(DownloadsModel.downloadsFolder) }
        context.commands.handle("downloads.clear") { _ in model.clearFinished() }

        context.ui.contribute("sidebar.footer", id: "downloads.button", order: 90) { window in DownloadsButton(window: window, model: model) }
        context.ui.contribute(.overlay, id: "downloads.panel", order: 60) { window in DownloadsPanel(window: window, model: model) }
        context.ui.contribute(.overlay, id: "downloads.fly", order: 300) { window in FlyingDownload(window: window, model: model) }
    }

    func handle(_ event: DownloadEvent) {
        switch event {
        case .started(let item):
            model.add(item)
            if context.settings.bool("downloads.flyAnimation") { model.flyToken += 1 }
        case .progress:
            break
        case .finished(let item):
            model.finished(item)
            context.notify("Downloaded \(item.destination?.lastPathComponent ?? item.suggestedFilename)",
                           systemImage: "arrow.down.circle.fill", actionTitle: "Show") {
                if let url = item.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .failed(let item, let message):
            model.finished(item)
            context.notify("Download failed: \(message)", systemImage: "exclamationmark.triangle")
        }
    }
}

@Observable
final class DownloadsModel {
    private(set) var items: [DownloadItem] = []
    var flyToken = 0

    /// The user's Downloads folder; with an isolated data directory (BROWSER_DATA_DIR: tests, automation), one inside it.
    static var downloadsFolder: URL {
        if let data = ProcessInfo.processInfo.environment["BROWSER_DATA_DIR"] {
            let folder = URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func add(_ item: DownloadItem) {
        items.removeAll { $0 === item }
        items.insert(item, at: 0)
    }

    func finished(_ item: DownloadItem) {
        if !items.contains(where: { $0 === item }) { items.insert(item, at: 0) }
    }

    func clearFinished() { items.removeAll { $0.isFinished || $0.error != nil } }

    var active: [DownloadItem] { items.filter { !$0.isFinished && $0.error == nil } }

    /// Aggregate progress of active downloads for the footer ring.
    var progress: Double? {
        let a = active
        guard !a.isEmpty else { return nil }
        let total = a.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
        guard total > 0 else { return 0 }
        return Double(a.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(total)
    }

    /// `name.ext` → `name 2.ext` … like Finder.
    static func uniqueDestination(for name: String, in dir: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = dir.appendingPathComponent(safe.isEmpty ? "download" : safe)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while exists(url) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

struct DownloadsButton: View {
    let window: BrowserWindowState
    let model: DownloadsModel
    @State private var bounce = 0

    var body: some View {
        if !model.items.isEmpty {
            Button { window.toggle(flag: DownloadsFeature.panelFlag) } label: {
                ZStack {
                    if let p = model.progress {
                        Circle().stroke(.quaternary, lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.02, p)).stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: p)
                    }
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).symbolEffect(.bounce, value: bounce)
                }
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassControl(in: Circle())
            .help("Downloads (⌘⇧J)")
            .onChange(of: model.flyToken) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { bounce += 1 } }
        }
    }
}

/// Radian: the file icon flies from the page into the downloads button.
struct FlyingDownload: View {
    let window: BrowserWindowState
    let model: DownloadsModel
    @State private var flying = false
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if flying {
                let start = CGPoint(x: geo.size.width * 0.55, y: geo.size.height * 0.45)
                let end = CGPoint(x: window.isSidebarVisible ? window.sidebarWidth - 30 : geo.size.width - 40,
                                  y: window.isSidebarVisible ? geo.size.height - 20 : 20)
                Image(systemName: "doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .tint)
                    .shadow(radius: 6)
                    .scaleEffect(1 - progress * 0.6)
                    .opacity(1 - Double(progress) * 0.3)
                    .position(Self.arc(from: start, to: end, t: progress))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: model.flyToken) {
            progress = 0
            flying = true
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.6)) { progress = 1 } completion: { flying = false }
        }
    }

    /// Quadratic curve through a control point above the straight line.
    static func arc(from a: CGPoint, to b: CGPoint, t: CGFloat) -> CGPoint {
        let c = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 120)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

struct DownloadsPanel: View {
    let window: BrowserWindowState
    let model: DownloadsModel

    var body: some View {
        if window.flags.contains(DownloadsFeature.panelFlag) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { window.flags.remove(DownloadsFeature.panelFlag) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloads").font(.headline)
                        Spacer()
                        Button("Clear") { model.clearFinished() }.buttonStyle(.borderless)
                    }
                    ForEach(model.items.prefix(8)) { item in DownloadRow(item: item) }
                }
                .padding(14)
                .frame(width: 320)
                .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .padding(.leading, 10)
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (item.suggestedFilename as NSString).pathExtension) ?? .data))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.destination?.lastPathComponent ?? item.suggestedFilename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if item.isFinished {
                    Text(ByteCountFormatter.string(fromByteCount: max(item.receivedBytes, item.totalBytes), countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let error = item.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                } else {
                    ProgressView(value: item.fractionCompleted).controlSize(.small)
                }
            }
            Spacer()
            if item.isFinished, let url = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            } else if !item.isFinished, item.error == nil {
                Button { item.cancel?() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Cancel")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let url = item.destination, item.isFinished { NSWorkspace.shared.open(url) } }
    }
}
