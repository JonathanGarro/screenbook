import Foundation

// release date choice

public enum ReleasePicker {
    /// order of tmdb release types tried for the region: 3 theatrical, 2 limited, 4 digital, 5 physical, 6 tv, 1 premiere
    public static let preference = [3, 2, 4, 5, 6, 1]

    /// returns the release date for the region and its earliest digital date.
    /// falls back to tmdb's primary release_date when the region has no entries.
    public static func pick(_ dates: ReleaseDates?, region: String, fallback: String?) -> (release: String?, digital: String?) {
        let entries = dates?.results.first { $0.iso31661.uppercased() == region.uppercased() }?.releaseDates ?? []
        func earliest(_ type: Int) -> String? {
            entries.filter { $0.type == type }.compactMap { DateText.normalize($0.releaseDate) }.min()
        }
        let digital = earliest(4)
        for type in preference {
            if let d = earliest(type) { return (d, digital) }
        }
        return (DateText.normalize(fallback), digital)
    }
}

// episode math

public enum EpisodeMath {
    /// every aired regular episode, built from season episode counts and last_episode_to_air. specials (season 0) are skipped.
    public static func aired(seasons: [SeasonSummary], lastAired: EpisodeRef?) -> [EpisodeRef] {
        guard let last = lastAired, last.season > 0 else { return [] }
        var out: [EpisodeRef] = []
        for s in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where s.seasonNumber > 0 {
            if s.seasonNumber < last.season {
                if s.episodeCount > 0 {
                    out += (1...s.episodeCount).map { EpisodeRef(season: s.seasonNumber, episode: $0) }
                }
            } else if s.seasonNumber == last.season {
                out += (1...max(1, last.episode)).map { EpisodeRef(season: s.seasonNumber, episode: $0) }
            }
        }
        if !seasons.contains(where: { $0.seasonNumber == last.season }) {
            out += (1...max(1, last.episode)).map { EpisodeRef(season: last.season, episode: $0) }
        }
        return out
    }

    /// every regular episode up to and including the target, using season counts
    public static func upTo(_ target: EpisodeRef, seasons: [SeasonSummary]) -> [EpisodeRef] {
        var out: [EpisodeRef] = []
        for s in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) where s.seasonNumber > 0 && s.seasonNumber < target.season {
            if s.episodeCount > 0 {
                out += (1...s.episodeCount).map { EpisodeRef(season: s.seasonNumber, episode: $0) }
            }
        }
        if target.episode > 0 {
            out += (1...target.episode).map { EpisodeRef(season: target.season, episode: $0) }
        }
        return out
    }
}

// service

public enum WatchlistError: Error, LocalizedError {
    case notFound(Int)
    case ambiguous(Int)
    case notTV(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No saved title with TMDB id \(id)."
        case .ambiguous(let id): return "TMDB id \(id) matches both a movie and a show. Pass --movie or --tv."
        case .notTV(let id): return "TMDB id \(id) is not a saved TV show."
        }
    }
}

/// all watchlist behavior lives here so the app and the cli share it
public final class WatchlistService: @unchecked Sendable {
    public let db: Database
    public let paths: AppPaths
    public var config: AppConfig
    public var client: TMDBClient?
    public var now: @Sendable () -> Date

    public init(db: Database, paths: AppPaths, config: AppConfig, client: TMDBClient?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.paths = paths
        self.config = config
        self.client = client
        self.now = now
    }

    /// opens the standard database and builds a client from the resolved api key (client is nil without a key)
    public static func standard(paths: AppPaths = .standard()) throws -> WatchlistService {
        try paths.ensureDirectories()
        let db = try Database(path: paths.databaseURL.path)
        let config = ConfigStore.load(paths)
        let client = APIKeyStore.resolve(paths).map { TMDBClient(apiKey: $0, db: db) }
        return WatchlistService(db: db, paths: paths, config: config, client: client)
    }

    public var today: String { DateText.day(now()) }

    private func requireClient() throws -> TMDBClient {
        guard let client else { throw TMDBError.missingAPIKey }
        return client
    }

    // queries

    public func titles() throws -> [Title] {
        try db.allTitles()
    }

    /// resolves an id to one saved title, honoring an optional media type
    public func resolve(_ tmdbId: Int, _ type: MediaType? = nil) throws -> Title {
        let matches = try db.titles(tmdbId: tmdbId).filter { type == nil || $0.mediaType == type }
        if matches.isEmpty { throw WatchlistError.notFound(tmdbId) }
        if matches.count > 1 { throw WatchlistError.ambiguous(tmdbId) }
        return matches[0]
    }

    /// last released episode: tmdb's last aired, or the end of the latest listed season when all episodes are out
    public func effectiveLastAired(_ t: Title) throws -> EpisodeRef? {
        guard t.allAvailable else { return t.lastAired }
        let listed = try db.seasons(tmdbId: t.tmdbId).filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
        guard let last = listed.max(by: { $0.seasonNumber < $1.seasonNumber }) else { return t.lastAired }
        let end = EpisodeRef(season: last.seasonNumber, episode: last.episodeCount)
        return max(end, t.lastAired ?? end)
    }

    public func airedEpisodes(_ t: Title) throws -> [EpisodeRef] {
        guard t.mediaType == .tv else { return [] }
        return EpisodeMath.aired(seasons: try db.seasons(tmdbId: t.tmdbId), lastAired: try effectiveLastAired(t))
    }

    /// stops or resumes tracking. progress is kept either way. resuming refreshes the title and marks what
    /// aired in the meantime as already seen, so it shows as backlog without new-episode alerts.
    @discardableResult
    public func setStopped(_ tmdbId: Int, _ type: MediaType?, stopped: Bool) async throws -> Title {
        var t = try resolve(tmdbId, type)
        if stopped {
            t.stoppedOn = today
            try db.upsertTitle(t)
            return t
        }
        t.stoppedOn = nil
        try db.upsertTitle(t)
        if client != nil, let fresh = try? await refresh(t, ttl: 0) { t = fresh }
        if t.mediaType == .tv, let end = try effectiveLastAired(t) {
            t.seenSeason = end.season
            t.seenEpisode = end.episode
        }
        if t.mediaType == .movie, let d = t.regionReleaseDate, d <= today {
            t.releaseFlagged = true
        }
        try db.upsertTitle(t)
        return t
    }

    /// movies on the watchlist with a sent review count as watched on the review's finished date
    @discardableResult
    public func markReviewedMoviesWatched() throws -> Int {
        var changed = 0
        for r in try db.allReviews() where r.mediaType == .movie && r.isSent {
            guard var t = try db.title(tmdbId: r.tmdbId, mediaType: .movie), t.watchedOn == nil else { continue }
            t.watchedOn = r.finishedOn ?? today
            try db.upsertTitle(t)
            changed += 1
        }
        return changed
    }

    /// turns the all-episodes-out override on or off for a show
    public func setAllAvailable(_ t: Title, _ on: Bool) throws {
        guard var current = try db.title(tmdbId: t.tmdbId, mediaType: .tv) else { throw WatchlistError.notTV(t.tmdbId) }
        current.allAvailable = on
        // count everything now listed as already seen, so turning it on does not fire "new episode" alerts
        if on, let end = try effectiveLastAired(current) {
            current.seenSeason = end.season
            current.seenEpisode = end.episode
        }
        try db.upsertTitle(current)
    }

    public func unwatchedAired(_ t: Title) throws -> [EpisodeRef] {
        let watched = try db.watched(tmdbId: t.tmdbId)
        return try airedEpisodes(t).filter { !watched.contains($0) }
    }

    // add and remove

    public func search(_ text: String) async throws -> [SearchResult] {
        try await requireClient().search(text)
    }

    /// saves a search result. for tv, caughtUp marks every aired episode watched.
    @discardableResult
    public func add(_ result: SearchResult, caughtUp: Bool = false) async throws -> Title {
        guard let kind = result.kind else { throw TMDBError.decoding("result is not a movie or tv show") }
        let existing = try db.title(tmdbId: result.id, mediaType: kind)
        var t = try await fetchTitle(id: result.id, type: kind, existing: existing, ttl: CacheTTL.details)
        if existing == nil {
            t.addedOn = today
            switch kind {
            case .movie:
                // already released titles are not reported as new
                t.releaseFlagged = (t.regionReleaseDate.map { $0 <= today } ?? false)
            case .tv:
                t.seenSeason = t.lastAiredSeason
                t.seenEpisode = t.lastAiredEpisode
            }
        }
        try db.upsertTitle(t)
        if kind == .tv && caughtUp {
            try db.setWatched(tmdbId: t.tmdbId, try airedEpisodes(t), watched: true, on: today)
        }
        return t
    }

    @discardableResult
    public func remove(_ tmdbId: Int, _ type: MediaType? = nil) throws -> Title {
        let t = try resolve(tmdbId, type)
        try db.deleteTitle(tmdbId: t.tmdbId, mediaType: t.mediaType)
        return t
    }

    // refresh

    /// pulls fresh details and returns an updated title, keeping local fields (added_on, flags, seen pointer)
    func fetchTitle(id: Int, type: MediaType, existing: Title?, ttl: TimeInterval) async throws -> Title {
        let client = try requireClient()
        var t = existing ?? Title(tmdbId: id, mediaType: type, title: "", addedOn: today)
        switch type {
        case .movie:
            let m = try await client.movie(id, ttl: ttl)
            let picked = ReleasePicker.pick(m.releaseDates, region: config.region, fallback: m.releaseDate)
            t.title = m.title
            t.year = DateText.normalize(m.releaseDate).flatMap { Int($0.prefix(4)) } ?? picked.release.flatMap { Int($0.prefix(4)) }
            t.regionReleaseDate = picked.release
            t.digitalReleaseDate = picked.digital
            t.status = m.status
            t.overview = m.overview
            t.posterPath = m.posterPath
        case .tv:
            let s = try await client.tv(id, ttl: ttl)
            t.title = s.name
            t.regionReleaseDate = DateText.normalize(s.firstAirDate)
            t.year = t.regionReleaseDate.flatMap { Int($0.prefix(4)) }
            t.status = s.status
            t.seriesType = s.type
            t.overview = s.overview
            t.posterPath = s.posterPath
            t.lastAiredSeason = s.lastEpisodeToAir?.seasonNumber
            t.lastAiredEpisode = s.lastEpisodeToAir?.episodeNumber
            t.lastAiredDate = DateText.normalize(s.lastEpisodeToAir?.airDate)
            t.nextAirSeason = s.nextEpisodeToAir?.seasonNumber
            t.nextAirEpisode = s.nextEpisodeToAir?.episodeNumber
            t.nextAirDate = DateText.normalize(s.nextEpisodeToAir?.airDate)
            let seasons = (s.seasons ?? []).map {
                SeasonSummary(seasonNumber: $0.seasonNumber, episodeCount: $0.episodeCount ?? 0,
                              airDate: DateText.normalize($0.airDate), name: $0.name)
            }
            try db.replaceSeasons(tmdbId: id, seasons)
        }
        t.lastRefreshed = DateText.timestamp(now())
        return t
    }

    @discardableResult
    public func refresh(_ t: Title, ttl: TimeInterval = CacheTTL.details) async throws -> Title {
        let updated = try await fetchTitle(id: t.tmdbId, type: t.mediaType, existing: t, ttl: ttl)
        try db.upsertTitle(updated)
        return updated
    }

    // watch

    public func setWatched(_ tmdbId: Int, season: Int, episode: Int, watched: Bool = true) throws {
        let t = try resolve(tmdbId, .tv)
        try db.setWatched(tmdbId: t.tmdbId, [EpisodeRef(season: season, episode: episode)], watched: watched, on: today)
    }

    /// marks every regular episode up to the target watched. refreshes season counts first if none are stored.
    @discardableResult
    public func markAllUpTo(_ tmdbId: Int, season: Int, episode: Int) async throws -> Int {
        var t = try resolve(tmdbId, .tv)
        var seasons = try db.seasons(tmdbId: t.tmdbId)
        if seasons.isEmpty, client != nil {
            t = try await refresh(t)
            seasons = try db.seasons(tmdbId: t.tmdbId)
        }
        let list = EpisodeMath.upTo(EpisodeRef(season: season, episode: episode), seasons: seasons)
        try db.setWatched(tmdbId: t.tmdbId, list, watched: true, on: today)
        return list.count
    }

    public func episodes(_ t: Title, season: Int) async throws -> [EpisodeDetail] {
        try await requireClient().season(t.tmdbId, season).episodes
    }

    public func providers(_ t: Title) async throws -> ProviderInfo? {
        try await requireClient().providers(t.mediaType, t.tmdbId, region: config.region)
    }

    // check

    public var lastCheck: Date? {
        DateText.parseTimestamp(try? db.meta("last_check"))
    }

    public var lastReport: CheckReport? {
        guard let text = try? db.meta("last_report"), let data = text.data(using: .utf8) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(CheckReport.self, from: data)
    }

    /// refreshes every title and reports what is new since the previous check.
    /// force bypasses the one hour details cache.
    public func check(force: Bool = false, progress: ((Int, Int, String) -> Void)? = nil) async throws -> CheckReport {
        _ = try requireClient()
        let ttl: TimeInterval = force ? 0 : CacheTTL.details
        let checkedAt = now()
        var report = CheckReport(checkedAt: checkedAt, previousCheck: lastCheck, region: config.region)
        let day = today
        let soon = DateText.addDays(day, 30)
        let all = try titles()

        let tracked = all.filter { !$0.isStopped }
        for (i, old) in tracked.enumerated() {
            progress?(i + 1, tracked.count, old.title)
            var t: Title
            do {
                t = try await fetchTitle(id: old.tmdbId, type: old.mediaType, existing: old, ttl: ttl)
            } catch {
                report.errors.append("\(old.title): \(error.localizedDescription)")
                t = old
            }

            switch t.mediaType {
            case .movie:
                if let d = t.regionReleaseDate {
                    if d <= day && !t.releaseFlagged {
                        report.releasedMovies.append(t)
                        t.releaseFlagged = true
                    } else if d > day {
                        // a pushed back release gets reported again when it arrives
                        t.releaseFlagged = false
                        if d <= soon && t.watchedOn == nil { report.upcomingMovies.append(t) }
                    }
                }
            case .tv:
                let aired = try airedEpisodes(t)
                let watched = try db.watched(tmdbId: t.tmdbId)
                let unwatched = aired.filter { !watched.contains($0) }
                let newly = t.seen.map { seen in unwatched.filter { $0 > seen } } ?? []
                if !unwatched.isEmpty {
                    report.showsWithUnwatched.append(ShowUpdate(title: t, unwatchedCount: unwatched.count,
                                                                firstUnwatched: unwatched.first, newlyAired: newly))
                }
                if !t.allAvailable, let next = t.nextAirDate, next <= DateText.addDays(day, 7) {
                    report.upcomingEpisodes.append(t)
                }
                let released = try effectiveLastAired(t)
                t.seenSeason = released?.season ?? t.seenSeason
                t.seenEpisode = released?.episode ?? t.seenEpisode
            }
            try db.upsertTitle(t)
        }

        report.upcomingMovies.sort { ($0.regionReleaseDate ?? "") < ($1.regionReleaseDate ?? "") }
        report.upcomingEpisodes.sort { ($0.nextAirDate ?? "") < ($1.nextAirDate ?? "") }
        report.showsWithUnwatched.sort {
            ($0.newlyAired.isEmpty ? 1 : 0, $0.title.title.lowercased()) < ($1.newlyAired.isEmpty ? 1 : 0, $1.title.title.lowercased())
        }

        if config.streamingEnabled {
            let listed = report.releasedMovies + report.showsWithUnwatched.map(\.title)
            for t in listed {
                if let info = try? await providers(t) {
                    report.providers[t.id] = info
                }
            }
        }

        try db.setMeta("last_check", DateText.timestamp(checkedAt))
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(report), let text = String(data: data, encoding: .utf8) {
            try db.setMeta("last_report", text)
        }
        return report
    }

    // outputs

    /// writes outputs/digest.md and returns its path and text
    @discardableResult
    public func writeDigest(_ report: CheckReport) throws -> (url: URL, text: String) {
        try paths.ensureDirectories()
        let text = Digest.markdown(report, config: config)
        try text.write(to: paths.digestURL, atomically: true, encoding: .utf8)
        return (paths.digestURL, text)
    }

    @discardableResult
    public func exportCSV() throws -> URL {
        try paths.ensureDirectories()
        let rows = try titles().map { t -> [String] in
            [String(t.tmdbId), t.mediaType.rawValue, t.title, t.year.map(String.init) ?? "", t.regionReleaseDate ?? "",
             t.digitalReleaseDate ?? "", t.nextAirDate ?? "", t.status ?? "", t.addedOn]
        }
        let header = ["tmdb_id", "media_type", "title", "year", "region_release_date", "digital_release_date",
                      "next_air_date", "status", "added_on"]
        try TextTable.csv(header: header, rows: rows).write(to: paths.csvURL, atomically: true, encoding: .utf8)
        return paths.csvURL
    }
}
