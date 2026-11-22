import Foundation

// library summaries

/// display details for a title that is not on the watchlist, from cached tmdb details
public struct TitleSummary: Sendable, Hashable {
    public var posterPath: String?
    public var year: Int?
    public var overview: String?
    public var genres: [String]
    public var status: String?

    public var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") } }
}

extension WatchlistService {
    /// poster, year, overview, and genres for any movie or show, cached for 30 days
    public func summary(_ type: MediaType, _ tmdbId: Int) async throws -> TitleSummary {
        guard let client else { throw TMDBError.missingAPIKey }
        switch type {
        case .movie:
            let m = try await client.movie(tmdbId, ttl: CacheTTL.providers)
            return TitleSummary(posterPath: m.posterPath, year: DateText.normalize(m.releaseDate).flatMap { Int($0.prefix(4)) },
                                overview: m.overview, genres: (m.genres ?? []).map(\.name), status: m.status)
        case .tv:
            let s = try await client.tv(tmdbId, ttl: CacheTTL.providers)
            return TitleSummary(posterPath: s.posterPath, year: DateText.normalize(s.firstAirDate).flatMap { Int($0.prefix(4)) },
                                overview: s.overview, genres: [], status: s.status)
        }
    }

    /// adds a title you have reviewed back to the watchlist, keeping what the reviews say you watched
    @discardableResult
    public func addFromHistory(_ type: MediaType, _ tmdbId: Int) async throws -> Title {
        var t = try await add(SearchResult(id: tmdbId, mediaType: type.rawValue))
        let reviewed = try db.allReviews().filter { $0.tmdbId == tmdbId && $0.mediaType == type && $0.isSent }
        switch type {
        case .movie:
            try markReviewedMoviesWatched()
        case .tv:
            // watched through the last reviewed season, dated like that review
            if let last = reviewed.max(by: { $0.season < $1.season }) {
                let seasons = try db.seasons(tmdbId: tmdbId)
                if let count = seasons.first(where: { $0.seasonNumber == last.season })?.episodeCount, count > 0 {
                    let eps = EpisodeMath.upTo(EpisodeRef(season: last.season, episode: count), seasons: seasons)
                    try db.setWatched(tmdbId: tmdbId, eps, watched: true, on: last.finishedOn ?? today)
                }
            }
        }
        t = try resolve(tmdbId, type)
        return t
    }
}
