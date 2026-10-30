import Foundation

/// The site someone most likely means by what they typed (Safari's Top Hit): "x" for x.com, "gmail" for
/// mail.google.com. A site matches when the query starts its domain, one of its names, or a word of its pages' titles,
/// and ranks by how often and how lately it was visited. History providers hand their pages to it; nothing leaves the Mac.
public enum TopHit {
    /// A site as history knows it: visits to all its pages.
    public struct Site: Equatable, Sendable {
        /// Without `www.`.
        public var host: String
        public var scheme: String
        public var visits: Int
        public var lastVisit: Date
        /// Words of its most visited pages' titles, lowercased: a brand that isn't in the domain ("gmail").
        public var words: [String]

        public var url: URL { URL(string: "\(scheme)://\(host)/")! }
    }

    /// The query at the start of the domain counts most, then of one of its names (google in mail.google.com), then of
    /// a word of a title (Gmail in "Inbox - Gmail").
    public static func match(_ query: String, _ site: Site) -> Double? {
        let q = query.lowercased()
        guard !q.isEmpty, !q.contains(where: { $0 == " " || $0 == "/" }) else { return nil }
        if site.host.hasPrefix(q) { return 1 }
        // The last label is the top-level domain: "com" isn't a name.
        if site.host.split(separator: ".").dropLast().contains(where: { $0.hasPrefix(q) }) { return 0.8 }
        if q.count >= 3, site.words.contains(where: { $0.hasPrefix(q) }) { return 0.6 }
        return nil
    }

    /// Visits with a two-week half-life, as history ranks its pages.
    public static func frecency(_ site: Site, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(site.lastVisit) / 86_400)
        return (1 + log2(Double(max(1, site.visits)))) * pow(0.5, days / 14)
    }

    /// The best site for `query`, scored; nil if none matches.
    public static func best(_ query: String, in sites: [Site], now: Date = Date()) -> (site: Site, score: Double)? {
        sites.compactMap { site in match(query, site).map { (site, $0 * frecency(site, now: now)) } }.max { $0.1 < $1.1 }
    }

    /// Sure enough to go before the search: a site visited a few times lately. One letter says less, so it asks more.
    public static func isConfident(_ score: Double, query: String) -> Bool {
        score >= (query.count == 1 ? 2 : 1)
    }

    /// Sites from history pages: one per host, `www.` dropped, web pages only.
    public static func sites(from entries: [HistoryEntry]) -> [Site] {
        var byHost: [String: (site: Site, top: [(title: String, visits: Int)])] = [:]
        for e in entries {
            guard let scheme = e.url.scheme, ["http", "https"].contains(scheme), var host = e.url.host()?.lowercased() else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var known = byHost[host] ?? (Site(host: host, scheme: scheme, visits: 0, lastVisit: e.lastVisit, words: []), [])
            known.site.visits += max(1, e.visitCount)
            known.site.lastVisit = max(known.site.lastVisit, e.lastVisit)
            if scheme == "https" { known.site.scheme = scheme }
            if !e.title.isEmpty { known.top.append((e.title, e.visitCount)) }
            byHost[host] = known
        }
        return byHost.values.map { value in
            var site = value.site
            let titles = value.top.sorted { $0.visits > $1.visits }.prefix(3).map { $0.title.lowercased() }
            site.words = Array(Set(titles.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }))
            return site
        }
    }

    /// Brands whose site has another name, matched without history (typing "gma" is enough for Gmail).
    public static let aliases: [String: String] = [
        "gmail": "mail.google.com", "gcal": "calendar.google.com", "gdrive": "drive.google.com", "gdocs": "docs.google.com",
        "twitter": "x.com", "yt": "youtube.com", "fb": "facebook.com", "ig": "instagram.com",
    ]

    /// The site an alias names: the whole alias, or its start from three letters on.
    public static func alias(for query: String) -> URL? {
        let q = query.lowercased()
        let host = aliases[q] ?? (q.count >= 3 ? aliases.first { $0.key.count > 3 && $0.key.hasPrefix(q) }?.value : nil)
        return host.flatMap { URL(string: "https://\($0)/") }
    }
}
