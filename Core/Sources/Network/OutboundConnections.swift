import Foundation
import Observation

/// Security Core (Radian's "verify where your data goes"): every connection the browser makes by itself, as opposed to
/// pages, goes through here and is logged where the user can check it. `forkctl validate` keeps features and engines off
/// URLSession, so nothing goes around it. Chromium's own requests aren't seen here (see the Security Core feature).
@Observable
public final class OutboundConnections {
    nonisolated public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var date: Date
        /// Scheme, host and path: query strings (search suggestions carry what you type) stay out of the log.
        public var url: String
        public var host: String
        public var purpose: String
        /// The feature that asked, or `engine`.
        public var source: String
        public var status: Int?
        public var bytes: Int?
        public var failure: String?
        /// Kept in memory only (favicons: frequent, and a list of the sites you visit).
        public var transient = false

        public init(date: Date, url: String, host: String, purpose: String, source: String, status: Int? = nil, bytes: Int? = nil,
                    failure: String? = nil, transient: Bool = false) {
            self.date = date
            self.url = url
            self.host = host
            self.purpose = purpose
            self.source = source
            self.status = status
            self.bytes = bytes
            self.failure = failure
            self.transient = transient
        }
    }

    public static let limit = 500
    public private(set) var entries: [Entry] = []
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored nonisolated private let session: URLSession
    @ObservationIgnored nonisolated private let privateSession: URLSession

    /// `file`: where the log is kept between launches (nil: memory only); writes wait `saveDelay` to batch.
    public init(file: URL?, saveDelay: Duration = .seconds(2)) {
        self.file = file
        self.saveDelay = saveDelay
        session = URLSession(configuration: Self.cookieless(.default))
        privateSession = URLSession(configuration: Self.cookieless(.ephemeral))
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Fetches `request` and logs it. Private windows' requests use an ephemeral session and leave no trace here.
    nonisolated public func data(for request: URLRequest, purpose: String, source: String, isPrivate: Bool = false,
                                 transient: Bool = false) async throws -> (Data, URLResponse) {
        if isPrivate { return try await privateSession.data(for: request) }
        var entry = Entry(date: Date(), url: Self.loggedURL(request.url), host: request.url?.host() ?? "", purpose: purpose, source: source,
                          transient: transient)
        do {
            let (data, response) = try await session.data(for: request)
            entry.status = (response as? HTTPURLResponse)?.statusCode
            entry.bytes = data.count
            await record(entry)
            return (data, response)
        } catch {
            entry.failure = (error as? URLError).map { "\($0.code.rawValue)" } ?? error.localizedDescription
            await record(entry)
            throw error
        }
    }

    public func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        if !entry.transient { scheduleSave() }
    }

    public func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// The browser's own requests carry no cookies and keep none: nothing to tie them to you or to your browsing.
    nonisolated static func cookieless(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    nonisolated static func loggedURL(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }

    private func scheduleSave() {
        guard let file, !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            guard let delay = self?.saveDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.saveScheduled = false
            guard let data = try? JSONEncoder().encode(self.entries.filter { !$0.transient }) else { return }
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
