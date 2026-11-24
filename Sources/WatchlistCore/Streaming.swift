import Foundation

// streaming alerts: when a saved title shows up on one of your services, say so once.
// what each title was last seen on is kept per device, like release_flagged, so every device
// announces on its own schedule.

/// a title that arrived on one or more of your services since the last check
public struct StreamingUpdate: Codable, Hashable, Sendable {
    public var title: Title
    public var services: [String]

    public init(title: Title, services: [String]) {
        self.title = title
        self.services = services
    }
}

let streamingSchemaSQL = """
create table if not exists streaming_seen (
    tmdb_id integer not null,
    media_type text not null,
    provider_id integer not null,
    primary key (tmdb_id, media_type, provider_id)
);
"""

// provider 0 marks a title whose availability has been recorded once, so alerts start after that
private let baselineMarker = 0

extension Database {
    func streamingSeen(_ t: Title) throws -> Set<Int> {
        Set(try query("select provider_id from streaming_seen where tmdb_id = ? and media_type = ?",
                      [.of(t.tmdbId), .text(t.mediaType.rawValue)]).compactMap { $0.int("provider_id") })
    }

    func setStreamingSeen(_ t: Title, _ ids: Set<Int>) throws {
        try transaction {
            try execute("delete from streaming_seen where tmdb_id = ? and media_type = ?", [.of(t.tmdbId), .text(t.mediaType.rawValue)])
            for id in ids.union([baselineMarker]) {
                try execute("insert into streaming_seen (tmdb_id, media_type, provider_id) values (?, ?, ?)",
                            [.of(t.tmdbId), .text(t.mediaType.rawValue), .of(id)])
            }
        }
    }
}

extension ProviderInfo {
    /// providers included with a subscription or free, not rentals or purchases
    public var included: [Provider] {
        (flatrate ?? []) + (free ?? []) + (ads ?? [])
    }
}

extension WatchlistService {
    /// looks up each title on your services and returns the ones that arrived somewhere new.
    /// a title seen for the first time, or a service just added to the list, is recorded without an alert.
    func checkStreaming(_ titles: [Title]) async -> [StreamingUpdate] {
        let mine = Set(config.myServices)
        guard !mine.isEmpty, let client else { return [] }
        let baselined = Set((try? db.meta("streaming_services"))?.split(separator: ",").compactMap { Int($0) } ?? [])
        var updates: [StreamingUpdate] = []
        for t in titles where !t.isStopped && !(t.mediaType == .movie && t.watchedOn != nil) {
            // a failed lookup changes nothing; no entry for the region means it streams nowhere there
            let info: ProviderInfo?
            do { info = try await client.providers(t.mediaType, t.tmdbId, region: config.region, ttl: CacheTTL.streamingAlerts) }
            catch { continue }
            let offers = (info?.included ?? []).filter { mine.contains($0.providerId) }
            let now = Set(offers.map(\.providerId))
            let seen = (try? db.streamingSeen(t)) ?? []
            if seen.contains(baselineMarker) {
                let arrived = now.subtracting(seen).intersection(baselined)
                if !arrived.isEmpty {
                    var names: [String] = []
                    for p in offers where arrived.contains(p.providerId) && !names.contains(p.providerName) { names.append(p.providerName) }
                    updates.append(StreamingUpdate(title: t, services: names))
                }
            }
            try? db.setStreamingSeen(t, now)
        }
        try? db.setMeta("streaming_services", mine.sorted().map(String.init).joined(separator: ","))
        return updates
    }

    /// streaming services tmdb lists for your region, the most popular first
    public func streamingServices() async throws -> [Provider] {
        try await requireClient().regionProviders(region: config.region)
    }
}
