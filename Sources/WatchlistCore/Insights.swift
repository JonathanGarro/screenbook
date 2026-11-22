import Foundation

// ratings comparison

/// which outside score to compare against
public enum RatingSource: String, CaseIterable, Identifiable, Sendable {
    case rottenTomatoes
    case imdb

    public var id: String { rawValue }
    public var label: String { self == .imdb ? "IMDb" : "Rotten Tomatoes" }
    public var detail: String { self == .imdb ? "IMDb user rating" : "Rotten Tomatoes critics score" }
}

/// one reviewed movie with your rating and its outside scores
public struct RatingPoint: Identifiable, Hashable, Sendable {
    public var id: String
    public var tmdbId: Int
    public var title: String
    /// out of 5
    public var myRating: Double
    /// out of 10
    public var imdb: Double?
    /// percent
    public var rottenTomatoes: Int?
    public var genres: [String]
    public var finishedOn: String?

    /// your rating on a 0 to 100 scale
    public var mine: Double { myRating * 20 }

    /// the outside score on a 0 to 100 scale
    public func external(_ source: RatingSource) -> Double? {
        switch source {
        case .rottenTomatoes: return rottenTomatoes.map(Double.init)
        case .imdb: return imdb.map { $0 * 10 }
        }
    }

    /// positive when you liked it more than the outside score
    public func delta(_ source: RatingSource) -> Double? {
        external(source).map { mine - $0 }
    }
}

extension WatchlistService {
    /// movie reviews with a rating, joined with imdb and rotten tomatoes values from their notes and tmdb genres
    public func ratingPoints(vault explicit: URL? = nil, progress: ((Int, Int) -> Void)? = nil) async throws -> [RatingPoint] {
        let vault = try vaultURL(explicit)
        let index = try noteIndex(vault: vault)
        let movies = try db.allReviews().filter { $0.mediaType == .movie && $0.isSent }
        var out: [RatingPoint] = []
        for (i, r) in movies.enumerated() {
            progress?(i + 1, movies.count)
            guard let path = index[r.id] ?? r.exportPath,
                  let text = try? String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8) else { continue }
            var values: [String: String] = [:]
            for p in ObsidianNote.parse(text).properties { values[p.key] = ObsidianNote.scalar(p.value) }
            guard let rating = values["rating"].flatMap(Double.init) else { continue }
            let imdb = values["imdb_rating"].flatMap(Double.init)
            let rt = values["rotten_tomatoes"].flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
            guard imdb != nil || rt != nil else { continue }
            var genres: [String] = []
            if let client, let details = try? await client.movie(r.tmdbId, ttl: CacheTTL.providers) {
                genres = (details.genres ?? []).map(\.name)
            }
            out.append(RatingPoint(id: r.id, tmdbId: r.tmdbId, title: (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""),
                                   myRating: rating, imdb: imdb, rottenTomatoes: rt, genres: genres,
                                   finishedOn: DateText.normalize(values["finished_on"])))
        }
        return out
    }
}
