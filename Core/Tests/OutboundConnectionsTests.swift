import BrowserTesting
import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct OutboundConnectionsTests {
    let server: TestHTTPServer

    init() throws { server = try TestHTTPServer(pages: ["/list.txt": "||ads.example^"]) }

    func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: server.url(path))!) }

    @Test func logsTheBrowsersOwnRequestsWithoutQueries() async throws {
        let log = OutboundConnections(file: nil)
        let (data, _) = try await log.data(for: request("/list.txt?q=what+you+typed"), purpose: "filter list update", source: "adblock")
        #expect(String(decoding: data, as: UTF8.self) == "||ads.example^")
        let entry = try #require(log.entries.first)
        #expect(entry.host == "127.0.0.1" && entry.purpose == "filter list update" && entry.source == "adblock")
        #expect(entry.url == server.url("/list.txt") && entry.status == 200 && entry.bytes == 14)
    }

    @Test func privateRequestsLeaveNoTrace() async throws {
        let log = OutboundConnections(file: nil)
        _ = try await log.data(for: request("/list.txt"), purpose: "favicon", source: "engine", isPrivate: true)
        #expect(log.entries.isEmpty)
    }

    @Test func failuresAreLoggedToo() async {
        let log = OutboundConnections(file: nil)
        _ = try? await log.data(for: URLRequest(url: URL(string: "http://127.0.0.1:9/nothing")!), purpose: "search suggestions", source: "search")
        #expect(log.entries.first?.failure != nil)
    }

    @Test func keepsTheLatestEntries() {
        let log = OutboundConnections(file: nil)
        for i in 0..<(OutboundConnections.limit + 20) {
            log.record(.init(date: Date(), url: "https://h\(i).example/", host: "h\(i).example", purpose: "p", source: "s"))
        }
        #expect(log.entries.count == OutboundConnections.limit)
        #expect(log.entries.first?.host == "h\(OutboundConnections.limit + 19).example")
    }

    /// Favicons (the sites you visit) stay in memory; the rest survives a relaunch.
    @Test func keepsAllButFaviconsAcrossLaunches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbound-\(UUID().uuidString.prefix(6)).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = OutboundConnections(file: file, saveDelay: .milliseconds(20))
        _ = try await log.data(for: request("/list.txt"), purpose: "favicon", source: "engine", transient: true)
        _ = try await log.data(for: request("/list.txt"), purpose: "filter list update", source: "adblock")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(OutboundConnections(file: file).entries.map(\.purpose) == ["filter list update"])
    }
}
