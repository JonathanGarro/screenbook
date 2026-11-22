import Foundation

// stored models

public enum MediaType: String, Codable, Sendable, CaseIterable {
    case movie
    case tv

    public var label: String { self == .movie ? "Movie" : "TV" }
}

/// one saved title. mirrors a row in the titles table.
public struct Title: Identifiable, Hashable, Codable, Sendable {
    public var tmdbId: Int
    public var mediaType: MediaType
    public var title: String
    public var year: Int?
    /// movies: the release date chosen for the configured region (see README). tv: first air date.
    public var regionReleaseDate: String?
    public var addedOn: String

    public var digitalReleaseDate: String?
    public var status: String?
    public var overview: String?
    public var posterPath: String?

    public var lastAiredSeason: Int?
    public var lastAiredEpisode: Int?
    public var lastAiredDate: String?
    public var nextAirSeason: Int?
    public var nextAirEpisode: Int?
    public var nextAirDate: String?

    /// the last aired episode we had already seen at the previous check, used for "new since last check"
    public var seenSeason: Int?
    public var seenEpisode: Int?
    /// movies: set once the release date has been reported, so it is reported only once
    public var releaseFlagged: Bool
    public var lastRefreshed: String?
    /// movies: the day it was marked watched
    public var watchedOn: String?
    /// tv: treat every listed episode as released, for streaming drops that tmdb records as weekly broadcasts
    public var allAvailable: Bool
    /// tv: tmdb's series type, e.g. "Miniseries"
    public var seriesType: String?

    public var id: String { "\(mediaType.rawValue)-\(tmdbId)" }

    public init(tmdbId: Int, mediaType: MediaType, title: String, year: Int? = nil,
                regionReleaseDate: String? = nil, addedOn: String,
                digitalReleaseDate: String? = nil, status: String? = nil, overview: String? = nil,
                posterPath: String? = nil, lastAiredSeason: Int? = nil, lastAiredEpisode: Int? = nil,
                lastAiredDate: String? = nil, nextAirSeason: Int? = nil, nextAirEpisode: Int? = nil,
                nextAirDate: String? = nil, seenSeason: Int? = nil, seenEpisode: Int? = nil,
                releaseFlagged: Bool = false, lastRefreshed: String? = nil, watchedOn: String? = nil,
                allAvailable: Bool = false, seriesType: String? = nil) {
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.title = title
        self.year = year
        self.regionReleaseDate = regionReleaseDate
        self.addedOn = addedOn
        self.digitalReleaseDate = digitalReleaseDate
        self.status = status
        self.overview = overview
        self.posterPath = posterPath
        self.lastAiredSeason = lastAiredSeason
        self.lastAiredEpisode = lastAiredEpisode
        self.lastAiredDate = lastAiredDate
        self.nextAirSeason = nextAirSeason
        self.nextAirEpisode = nextAirEpisode
        self.nextAirDate = nextAirDate
        self.seenSeason = seenSeason
        self.seenEpisode = seenEpisode
        self.releaseFlagged = releaseFlagged
        self.lastRefreshed = lastRefreshed
        self.watchedOn = watchedOn
        self.allAvailable = allAvailable
        self.seriesType = seriesType
    }

    public var lastAired: EpisodeRef? {
        guard let s = lastAiredSeason, let e = lastAiredEpisode else { return nil }
        return EpisodeRef(season: s, episode: e)
    }

    public var nextAir: EpisodeRef? {
        guard let s = nextAirSeason, let e = nextAirEpisode else { return nil }
        return EpisodeRef(season: s, episode: e)
    }

    public var seen: EpisodeRef? {
        guard let s = seenSeason, let e = seenEpisode else { return nil }
        return EpisodeRef(season: s, episode: e)
    }

    /// the date shown in the "next" column: upcoming release for movies, next episode for tv
    public func nextDate(today: String) -> String? {
        switch mediaType {
        case .movie:
            if let d = regionReleaseDate, d > today { return d }
            if let d = digitalReleaseDate, d > today { return d }
            return nil
        case .tv:
            return allAvailable ? nil : nextAirDate
        }
    }

    public var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(posterPath)")
    }

    public var tmdbURL: URL? {
        URL(string: "https://www.themoviedb.org/\(mediaType.rawValue)/\(tmdbId)")
    }
}

public struct EpisodeRef: Hashable, Comparable, Codable, Sendable {
    public var season: Int
    public var episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    public static func < (a: EpisodeRef, b: EpisodeRef) -> Bool {
        (a.season, a.episode) < (b.season, b.episode)
    }

    public var code: String { String(format: "S%02dE%02d", season, episode) }
}

public struct SeasonSummary: Hashable, Codable, Sendable {
    public var seasonNumber: Int
    public var episodeCount: Int
    public var airDate: String?
    public var name: String?

    public init(seasonNumber: Int, episodeCount: Int, airDate: String? = nil, name: String? = nil) {
        self.seasonNumber = seasonNumber
        self.episodeCount = episodeCount
        self.airDate = airDate
        self.name = name
    }
}

// reviews

/// a review draft or sent review. movies use season 0; tv reviews are per season.
public struct Review: Codable, Hashable, Identifiable, Sendable {
    public var tmdbId: Int
    public var mediaType: MediaType
    public var season: Int
    public var noteTitle: String
    public var rating: Double?
    public var finishedOn: String?
    public var body: String
    public var rewatch: Bool
    public var connectedTo: String?
    public var seriesIndex: Int?
    public var exportedAt: String?
    public var exportPath: String?
    public var updatedAt: String
    /// saved in watchlist after it was last sent, so the note does not have these edits yet
    public var localEdits: Bool = false

    public var id: String { "\(mediaType.rawValue)-\(tmdbId)-\(season)" }
    public var isSent: Bool { exportPath != nil }

    public init(tmdbId: Int, mediaType: MediaType, season: Int = 0, noteTitle: String, rating: Double? = nil,
                finishedOn: String? = nil, body: String = "", rewatch: Bool = false, connectedTo: String? = nil,
                seriesIndex: Int? = nil, exportedAt: String? = nil, exportPath: String? = nil, updatedAt: String = "") {
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.season = season
        self.noteTitle = noteTitle
        self.rating = rating
        self.finishedOn = finishedOn
        self.body = body
        self.rewatch = rewatch
        self.connectedTo = connectedTo
        self.seriesIndex = seriesIndex
        self.exportedAt = exportedAt
        self.exportPath = exportPath
        self.updatedAt = updatedAt
    }
}

// check results

public struct ShowUpdate: Codable, Hashable, Sendable {
    public var title: Title
    public var unwatchedCount: Int
    public var firstUnwatched: EpisodeRef?
    public var newlyAired: [EpisodeRef]
}

public struct CheckReport: Codable, Sendable {
    public var checkedAt: Date
    public var previousCheck: Date?
    public var releasedMovies: [Title]
    public var upcomingMovies: [Title]
    public var showsWithUnwatched: [ShowUpdate]
    public var upcomingEpisodes: [Title]
    public var providers: [String: ProviderInfo]
    public var errors: [String]
    public var region: String

    public init(checkedAt: Date, previousCheck: Date?, releasedMovies: [Title] = [], upcomingMovies: [Title] = [],
                showsWithUnwatched: [ShowUpdate] = [], upcomingEpisodes: [Title] = [],
                providers: [String: ProviderInfo] = [:], errors: [String] = [], region: String = "US") {
        self.checkedAt = checkedAt
        self.previousCheck = previousCheck
        self.releasedMovies = releasedMovies
        self.upcomingMovies = upcomingMovies
        self.showsWithUnwatched = showsWithUnwatched
        self.upcomingEpisodes = upcomingEpisodes
        self.providers = providers
        self.errors = errors
        self.region = region
    }

    public var newEpisodeShows: [ShowUpdate] { showsWithUnwatched.filter { !$0.newlyAired.isEmpty } }
    public var hasNews: Bool { !releasedMovies.isEmpty || !newEpisodeShows.isEmpty }
}

// streaming

public struct Provider: Codable, Hashable, Sendable {
    public var providerId: Int
    public var providerName: String
    public var logoPath: String?
    public var displayPriority: Int?

    public var logoURL: URL? {
        guard let logoPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w45\(logoPath)")
    }
}

public struct ProviderInfo: Codable, Hashable, Sendable {
    public var link: String?
    public var flatrate: [Provider]?
    public var rent: [Provider]?
    public var buy: [Provider]?
    public var ads: [Provider]?
    public var free: [Provider]?

    public func names(includeRentBuy: Bool) -> [String] {
        var list = (flatrate ?? []).sorted { ($0.displayPriority ?? 999) < ($1.displayPriority ?? 999) }.map(\.providerName)
        if includeRentBuy {
            list += (rent ?? []).map { "\($0.providerName) (rent)" }
            list += (buy ?? []).map { "\($0.providerName) (buy)" }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

// dates

public enum DateText {
    /// yyyy-MM-dd in the local time zone
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// accepts "2024-05-01" or "2024-05-01T00:00:00.000Z" and returns the first ten characters; empty becomes nil
    public static func normalize(_ text: String?) -> String? {
        guard let text, text.count >= 10 else { return nil }
        return String(text.prefix(10))
    }

    public static func addDays(_ day: String, _ days: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day),
              let moved = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: d) else { return day }
        return f.string(from: moved)
    }

    /// friendly form like "Fri, Nov 21" for display
    public static func pretty(_ day: String?) -> String {
        guard let day else { return "" }
        let inF = DateFormatter()
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: day) else { return day }
        let outF = DateFormatter()
        outF.setLocalizedDateFormatFromTemplate("EEE MMM d yyyy")
        return outF.string(from: d)
    }
}
