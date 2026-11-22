import Foundation
import SQLite3

// values

public enum SQLValue: Equatable, Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    public static func of(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    public static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
    public static func of(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
}

public typealias Row = [String: SQLValue]

extension Dictionary where Key == String, Value == SQLValue {
    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .text(let s): return Int(s)
        default: return nil
        }
    }

    func string(_ key: String) -> String? {
        switch self[key] {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
}

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "could not open database: \(m)"
        case .prepare(let m): return "sql prepare failed: \(m)"
        case .step(let m): return "sql step failed: \(m)"
        }
    }
}

// schema

private let schemaSQL = """
create table if not exists titles (
    tmdb_id integer not null,
    media_type text not null check (media_type in ('movie', 'tv')),
    title text not null,
    year integer,
    region_release_date text,
    added_on text not null,
    digital_release_date text,
    status text,
    overview text,
    poster_path text,
    last_aired_season integer,
    last_aired_episode integer,
    last_aired_date text,
    next_air_season integer,
    next_air_episode integer,
    next_air_date text,
    seen_season integer,
    seen_episode integer,
    release_flagged integer not null default 0,
    last_refreshed text,
    primary key (tmdb_id, media_type)
);
create table if not exists watched_episodes (
    tmdb_id integer not null,
    season integer not null,
    episode integer not null,
    watched_on text,
    primary key (tmdb_id, season, episode)
);
create table if not exists seasons (
    tmdb_id integer not null,
    season_number integer not null,
    episode_count integer not null,
    air_date text,
    name text,
    primary key (tmdb_id, season_number)
);
create table if not exists api_cache (
    cache_key text primary key,
    body text not null,
    fetched_at text not null
);
create table if not exists meta (
    key text primary key,
    value text
);
create table if not exists reviews (
    tmdb_id integer not null,
    media_type text not null,
    season integer not null default 0,
    note_title text not null,
    rating real,
    finished_on text,
    body text not null default '',
    rewatch integer not null default 0,
    connected_to text,
    series_index integer,
    exported_at text,
    export_path text,
    updated_at text not null,
    primary key (tmdb_id, media_type, season)
);
"""

// connection

/// thin sqlite wrapper plus the typed queries the app needs. safe to share across threads.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        if path != ":memory:" {
            try exec("pragma journal_mode = wal;")
        }
        try exec(schemaSQL)
        try migrate()
    }

    /// additive column changes for databases created by older versions
    private func migrate() throws {
        let cols = try query("pragma table_info(titles)").compactMap { $0.string("name") }
        if !cols.contains("watched_on") {
            try exec("alter table titles add column watched_on text;")
        }
        let reviewCols = try query("pragma table_info(reviews)").compactMap { $0.string("name") }
        if !reviewCols.contains("local_edits") {
            try exec("alter table reviews add column local_edits integer not null default 0;")
        }
        if !cols.contains("stopped_on") {
            try exec("alter table titles add column stopped_on text;")
        }
        if !cols.contains("series_type") {
            try exec("alter table titles add column series_type text;")
        }
        if !cols.contains("all_available") {
            try exec("alter table titles add column all_available integer not null default 0;")
        }
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        sqlite3_close(handle)
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DatabaseError.step(message)
        }
    }

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare("\(lastError) in: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Database.transient)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError.step(lastError) }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_NULL: row[name] = .null
                default:
                    if let text = sqlite3_column_text(stmt, c) {
                        row[name] = .text(String(cString: text))
                    } else {
                        row[name] = .null
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("begin;")
        do {
            let result = try body()
            try exec("commit;")
            return result
        } catch {
            try? exec("rollback;")
            throw error
        }
    }
}

// titles

extension Database {
    public func upsertTitle(_ t: Title) throws {
        try execute("""
            insert into titles (tmdb_id, media_type, title, year, region_release_date, added_on,
                digital_release_date, status, overview, poster_path,
                last_aired_season, last_aired_episode, last_aired_date,
                next_air_season, next_air_episode, next_air_date,
                seen_season, seen_episode, release_flagged, last_refreshed, watched_on, all_available, series_type, stopped_on)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            on conflict (tmdb_id, media_type) do update set
                title = excluded.title, year = excluded.year,
                region_release_date = excluded.region_release_date,
                digital_release_date = excluded.digital_release_date,
                status = excluded.status, overview = excluded.overview, poster_path = excluded.poster_path,
                last_aired_season = excluded.last_aired_season, last_aired_episode = excluded.last_aired_episode,
                last_aired_date = excluded.last_aired_date,
                next_air_season = excluded.next_air_season, next_air_episode = excluded.next_air_episode,
                next_air_date = excluded.next_air_date,
                seen_season = excluded.seen_season, seen_episode = excluded.seen_episode,
                release_flagged = excluded.release_flagged, last_refreshed = excluded.last_refreshed,
                watched_on = excluded.watched_on, all_available = excluded.all_available,
                series_type = excluded.series_type, stopped_on = excluded.stopped_on
            """, [
                .of(t.tmdbId), .text(t.mediaType.rawValue), .text(t.title), .of(t.year), .of(t.regionReleaseDate),
                .text(t.addedOn), .of(t.digitalReleaseDate), .of(t.status), .of(t.overview), .of(t.posterPath),
                .of(t.lastAiredSeason), .of(t.lastAiredEpisode), .of(t.lastAiredDate),
                .of(t.nextAirSeason), .of(t.nextAirEpisode), .of(t.nextAirDate),
                .of(t.seenSeason), .of(t.seenEpisode), .of(t.releaseFlagged), .of(t.lastRefreshed),
                .of(t.watchedOn), .of(t.allAvailable), .of(t.seriesType), .of(t.stoppedOn),
            ])
    }

    public func allTitles() throws -> [Title] {
        try query("select * from titles order by lower(title)").map(Database.title(from:))
    }

    public func title(tmdbId: Int, mediaType: MediaType) throws -> Title? {
        try query("select * from titles where tmdb_id = ? and media_type = ?",
                  [.of(tmdbId), .text(mediaType.rawValue)]).first.map(Database.title(from:))
    }

    public func titles(tmdbId: Int) throws -> [Title] {
        try query("select * from titles where tmdb_id = ?", [.of(tmdbId)]).map(Database.title(from:))
    }

    /// removes the title and, for tv, its watched episodes and season rows
    public func deleteTitle(tmdbId: Int, mediaType: MediaType) throws {
        try transaction {
            try execute("delete from titles where tmdb_id = ? and media_type = ?", [.of(tmdbId), .text(mediaType.rawValue)])
            if mediaType == .tv {
                try execute("delete from watched_episodes where tmdb_id = ?", [.of(tmdbId)])
                try execute("delete from seasons where tmdb_id = ?", [.of(tmdbId)])
            }
        }
    }

    static func title(from r: Row) -> Title {
        Title(
            tmdbId: r.int("tmdb_id") ?? 0,
            mediaType: MediaType(rawValue: r.string("media_type") ?? "movie") ?? .movie,
            title: r.string("title") ?? "",
            year: r.int("year"),
            regionReleaseDate: r.string("region_release_date"),
            addedOn: r.string("added_on") ?? "",
            digitalReleaseDate: r.string("digital_release_date"),
            status: r.string("status"),
            overview: r.string("overview"),
            posterPath: r.string("poster_path"),
            lastAiredSeason: r.int("last_aired_season"),
            lastAiredEpisode: r.int("last_aired_episode"),
            lastAiredDate: r.string("last_aired_date"),
            nextAirSeason: r.int("next_air_season"),
            nextAirEpisode: r.int("next_air_episode"),
            nextAirDate: r.string("next_air_date"),
            seenSeason: r.int("seen_season"),
            seenEpisode: r.int("seen_episode"),
            releaseFlagged: r.bool("release_flagged"),
            lastRefreshed: r.string("last_refreshed"),
            watchedOn: r.string("watched_on"),
            allAvailable: r.bool("all_available"),
            seriesType: r.string("series_type"),
            stoppedOn: r.string("stopped_on")
        )
    }
}

// seasons and watched episodes

extension Database {
    public func replaceSeasons(tmdbId: Int, _ seasons: [SeasonSummary]) throws {
        try transaction {
            try execute("delete from seasons where tmdb_id = ?", [.of(tmdbId)])
            for s in seasons {
                try execute("insert into seasons (tmdb_id, season_number, episode_count, air_date, name) values (?, ?, ?, ?, ?)",
                            [.of(tmdbId), .of(s.seasonNumber), .of(s.episodeCount), .of(s.airDate), .of(s.name)])
            }
        }
    }

    public func seasons(tmdbId: Int) throws -> [SeasonSummary] {
        try query("select * from seasons where tmdb_id = ? order by season_number", [.of(tmdbId)]).map {
            SeasonSummary(seasonNumber: $0.int("season_number") ?? 0, episodeCount: $0.int("episode_count") ?? 0,
                          airDate: $0.string("air_date"), name: $0.string("name"))
        }
    }

    public func setWatched(tmdbId: Int, _ episodes: [EpisodeRef], watched: Bool, on day: String) throws {
        try transaction {
            for ep in episodes {
                if watched {
                    try execute("insert or ignore into watched_episodes (tmdb_id, season, episode, watched_on) values (?, ?, ?, ?)",
                                [.of(tmdbId), .of(ep.season), .of(ep.episode), .text(day)])
                } else {
                    try execute("delete from watched_episodes where tmdb_id = ? and season = ? and episode = ?",
                                [.of(tmdbId), .of(ep.season), .of(ep.episode)])
                }
            }
        }
    }

    public func watched(tmdbId: Int) throws -> Set<EpisodeRef> {
        Set(try query("select season, episode from watched_episodes where tmdb_id = ?", [.of(tmdbId)]).map {
            EpisodeRef(season: $0.int("season") ?? 0, episode: $0.int("episode") ?? 0)
        })
    }
}

// cache and meta

extension Database {
    public func cacheGet(_ key: String) throws -> (body: String, fetchedAt: Date)? {
        guard let row = try query("select body, fetched_at from api_cache where cache_key = ?", [.text(key)]).first,
              let body = row.string("body"),
              let date = DateText.parseTimestamp(row.string("fetched_at")) else { return nil }
        return (body, date)
    }

    public func cachePut(_ key: String, body: String, at date: Date) throws {
        try execute("insert or replace into api_cache (cache_key, body, fetched_at) values (?, ?, ?)",
                    [.text(key), .text(body), .text(DateText.timestamp(date))])
    }

    public func clearCache() throws {
        try execute("delete from api_cache")
    }

    public func meta(_ key: String) throws -> String? {
        try query("select value from meta where key = ?", [.text(key)]).first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try execute("insert or replace into meta (key, value) values (?, ?)", [.text(key), .of(value)])
    }
}

// reviews

extension Database {
    public func upsertReview(_ r: Review) throws {
        try execute("""
            insert or replace into reviews (tmdb_id, media_type, season, note_title, rating, finished_on, body,
                rewatch, connected_to, series_index, exported_at, export_path, updated_at, local_edits)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .of(r.tmdbId), .text(r.mediaType.rawValue), .of(r.season), .text(r.noteTitle),
                r.rating.map { .double($0) } ?? .null, .of(r.finishedOn), .text(r.body), .of(r.rewatch),
                .of(r.connectedTo), .of(r.seriesIndex), .of(r.exportedAt), .of(r.exportPath), .text(r.updatedAt),
                .of(r.localEdits),
            ])
    }

    public func review(tmdbId: Int, mediaType: MediaType, season: Int) throws -> Review? {
        try query("select * from reviews where tmdb_id = ? and media_type = ? and season = ?",
                  [.of(tmdbId), .text(mediaType.rawValue), .of(season)]).first.map(Database.review(from:))
    }

    public func allReviews() throws -> [Review] {
        try query("select * from reviews order by updated_at desc").map(Database.review(from:))
    }

    public func deleteReview(tmdbId: Int, mediaType: MediaType, season: Int) throws {
        try execute("delete from reviews where tmdb_id = ? and media_type = ? and season = ?",
                    [.of(tmdbId), .text(mediaType.rawValue), .of(season)])
    }

    /// latest day any episode of the season was checked off
    public func lastWatchedDay(tmdbId: Int, season: Int) throws -> String? {
        try query("select max(watched_on) as d from watched_episodes where tmdb_id = ? and season = ?",
                  [.of(tmdbId), .of(season)]).first?.string("d")
    }

    static func review(from r: Row) -> Review {
        var rating: Double?
        if case .double(let v) = r["rating"] { rating = v }
        if case .int(let v) = r["rating"] { rating = Double(v) }
        var review = Review(
            tmdbId: r.int("tmdb_id") ?? 0,
            mediaType: MediaType(rawValue: r.string("media_type") ?? "movie") ?? .movie,
            season: r.int("season") ?? 0,
            noteTitle: r.string("note_title") ?? "",
            rating: rating,
            finishedOn: r.string("finished_on"),
            body: r.string("body") ?? "",
            rewatch: r.bool("rewatch"),
            connectedTo: r.string("connected_to"),
            seriesIndex: r.int("series_index"),
            exportedAt: r.string("exported_at"),
            exportPath: r.string("export_path"),
            updatedAt: r.string("updated_at") ?? ""
        )
        review.localEdits = r.bool("local_edits")
        return review
    }
}
