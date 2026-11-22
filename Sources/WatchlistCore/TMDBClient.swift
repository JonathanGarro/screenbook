import Foundation

// transport

/// the network seam. tests swap in a mock so no live calls happen.
public protocol HTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TMDBError.http(0, "no http response")
        }
        return (data, http)
    }
}

public enum TMDBError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(Int, String)
    case rateLimited
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No TMDB API key. Set TMDB_API_KEY or add it in Settings."
        case .http(let code, let message):
            if code == 401 { return "TMDB rejected the API key (401). Check TMDB_API_KEY." }
            return "TMDB request failed (\(code)): \(message)"
        case .rateLimited:
            return "TMDB rate limit hit repeatedly. Try again in a minute."
        case .decoding(let m):
            return "Could not read TMDB response: \(m)"
        }
    }
}

// cache lifetimes

public enum CacheTTL {
    public static let search: TimeInterval = 24 * 3600
    /// details refreshed by check; one hour keeps repeated runs from hitting the api
    public static let details: TimeInterval = 3600
    public static let season: TimeInterval = 6 * 3600
    /// providers refresh at most every 30 days
    public static let providers: TimeInterval = 30 * 24 * 3600
}

// response shapes (field names confirmed against developer.themoviedb.org reference)

public struct SearchResult: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let mediaType: String?
    public let title: String?
    public let name: String?
    public let releaseDate: String?
    public let firstAirDate: String?
    public let overview: String?
    public let posterPath: String?
    public let popularity: Double?
    public let originalTitle: String?
    public let originalName: String?

    public var kind: MediaType? { mediaType.flatMap(MediaType.init(rawValue:)) }
    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var date: String? { DateText.normalize(releaseDate ?? firstAirDate) }
    public var year: Int? { date.flatMap { Int($0.prefix(4)) } }
    public var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w92\($0)") } }

    public init(id: Int, mediaType: String?, title: String? = nil, name: String? = nil, releaseDate: String? = nil,
                firstAirDate: String? = nil, overview: String? = nil, posterPath: String? = nil, popularity: Double? = nil,
                originalTitle: String? = nil, originalName: String? = nil) {
        self.id = id
        self.mediaType = mediaType
        self.title = title
        self.name = name
        self.releaseDate = releaseDate
        self.firstAirDate = firstAirDate
        self.overview = overview
        self.posterPath = posterPath
        self.popularity = popularity
        self.originalTitle = originalTitle
        self.originalName = originalName
    }

    /// copy with the media type filled in, for endpoints that omit media_type
    public func withKind(_ kind: MediaType) -> SearchResult {
        SearchResult(id: id, mediaType: kind.rawValue, title: title, name: name, releaseDate: releaseDate,
                     firstAirDate: firstAirDate, overview: overview, posterPath: posterPath, popularity: popularity,
                     originalTitle: originalTitle, originalName: originalName)
    }
}

struct FindResponse: Decodable {
    let movieResults: [SearchResult]?
    let tvResults: [SearchResult]?
}

struct SearchPage: Decodable {
    let results: [SearchResult]
}

public struct ReleaseDateEntry: Decodable, Sendable {
    public let certification: String?
    public let note: String?
    public let releaseDate: String?
    public let type: Int?
}

public struct ReleaseDateCountry: Decodable, Sendable {
    public let iso31661: String
    public let releaseDates: [ReleaseDateEntry]
}

public struct ReleaseDates: Decodable, Sendable {
    public let results: [ReleaseDateCountry]
}

public struct MovieDetails: Decodable, Sendable {
    public let id: Int
    public let title: String
    public let releaseDate: String?
    public let status: String?
    public let overview: String?
    public let posterPath: String?
    public let imdbId: String?
    public let releaseDates: ReleaseDates?
    public let belongsToCollection: CollectionRef?
}

public struct CollectionRef: Decodable, Sendable {
    public let id: Int
    public let name: String
}

public struct CollectionDetails: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let parts: [SearchResult]
}

public struct EpisodeSummary: Decodable, Sendable {
    public let airDate: String?
    public let episodeNumber: Int
    public let seasonNumber: Int
    public let name: String?
}

public struct TVSeason: Decodable, Sendable {
    public let seasonNumber: Int
    public let episodeCount: Int?
    public let airDate: String?
    public let name: String?
}

public struct TVDetails: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let firstAirDate: String?
    public let status: String?
    public let inProduction: Bool?
    /// e.g. "Scripted", "Miniseries", "Documentary"
    public let type: String?
    public let numberOfSeasons: Int?
    public let overview: String?
    public let posterPath: String?
    public let seasons: [TVSeason]?
    public let lastEpisodeToAir: EpisodeSummary?
    public let nextEpisodeToAir: EpisodeSummary?
}

public struct EpisodeDetail: Decodable, Identifiable, Hashable, Sendable {
    public let airDate: String?
    public let episodeNumber: Int
    public let seasonNumber: Int
    public let name: String?
    public let overview: String?
    public let runtime: Int?

    public var id: String { "\(seasonNumber)-\(episodeNumber)" }
    public var ref: EpisodeRef { EpisodeRef(season: seasonNumber, episode: episodeNumber) }
}

public struct SeasonDetails: Decodable, Sendable {
    public let seasonNumber: Int?
    public let episodes: [EpisodeDetail]
}

struct ProvidersResponse: Decodable {
    let results: [String: ProviderInfo]
}

// client

/// tmdb v3 wrapper with sqlite response caching, a small gap between calls, and 429 backoff
public actor TMDBClient {
    public static let baseURL = URL(string: "https://api.themoviedb.org/3")!

    private let apiKey: String
    private let db: Database
    private let transport: HTTPTransport
    private let minInterval: TimeInterval
    private let maxRetries: Int
    private let backoffBase: TimeInterval
    private let now: @Sendable () -> Date
    private var lastRequest: Date?
    public private(set) var networkCalls = 0

    public init(apiKey: String, db: Database, transport: HTTPTransport = URLSessionTransport(),
                minInterval: TimeInterval = 0.25, maxRetries: Int = 4, backoffBase: TimeInterval = 1.0,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.apiKey = apiKey
        self.db = db
        self.transport = transport
        self.minInterval = minInterval
        self.maxRetries = maxRetries
        self.backoffBase = backoffBase
        self.now = now
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// v4 read access tokens are jwts and go in the authorization header; v3 keys go in api_key
    private var usesBearer: Bool { apiKey.hasPrefix("eyJ") }

    static func cacheKey(path: String, query: [String: String]) -> String {
        let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return q.isEmpty ? path : "\(path)?\(q)"
    }

    /// returns the cached body if younger than ttl, otherwise fetches. on network failure a stale cache entry is used.
    public func get(_ path: String, query: [String: String] = [:], ttl: TimeInterval) async throws -> Data {
        let key = Self.cacheKey(path: path, query: query)
        let cached = try? db.cacheGet(key)
        if let cached, now().timeIntervalSince(cached.fetchedAt) < ttl {
            return Data(cached.body.utf8)
        }
        do {
            let data = try await fetch(path, query: query)
            if let body = String(data: data, encoding: .utf8) {
                try? db.cachePut(key, body: body, at: now())
            }
            return data
        } catch let error as TMDBError {
            throw error
        } catch {
            if let cached { return Data(cached.body.utf8) }
            throw error
        }
    }

    private func throttle() async {
        if let last = lastRequest {
            let wait = minInterval - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequest = Date()
    }

    private func fetch(_ path: String, query: [String: String]) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !usesBearer {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        if usesBearer {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var attempt = 0
        while true {
            await throttle()
            networkCalls += 1
            let (data, response) = try await transport.get(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 429:
                attempt += 1
                if attempt > maxRetries { throw TMDBError.rateLimited }
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let wait = retryAfter ?? backoffBase * pow(2, Double(attempt - 1))
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            default:
                let message = Self.statusMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                throw TMDBError.http(response.statusCode, message)
            }
        }
    }

    private static func statusMessage(_ data: Data) -> String? {
        struct Status: Decodable { let statusMessage: String? }
        return (try? decoder().decode(Status.self, from: data))?.statusMessage
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.decoder().decode(type, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }

    // endpoints

    /// search/multi, keeping only movies and tv (people are dropped)
    public func search(_ text: String) async throws -> [SearchResult] {
        let data = try await get("search/multi", query: ["query": text, "include_adult": "false", "language": "en-US", "page": "1"],
                                 ttl: CacheTTL.search)
        return try decode(SearchPage.self, data).results.filter { $0.kind != nil }
    }

    public func searchMovies(_ text: String, year: Int? = nil) async throws -> [SearchResult] {
        var q = ["query": text, "include_adult": "false", "language": "en-US", "page": "1"]
        if let year { q["year"] = String(year) }
        let data = try await get("search/movie", query: q, ttl: CacheTTL.search)
        return try decode(SearchPage.self, data).results.map { $0.withKind(.movie) }
    }

    public func searchShows(_ text: String, year: Int? = nil) async throws -> [SearchResult] {
        var q = ["query": text, "include_adult": "false", "language": "en-US", "page": "1"]
        if let year { q["first_air_date_year"] = String(year) }
        let data = try await get("search/tv", query: q, ttl: CacheTTL.search)
        return try decode(SearchPage.self, data).results.map { $0.withKind(.tv) }
    }

    /// looks up a title by imdb id via /find
    public func find(imdbId: String) async throws -> (movies: [SearchResult], shows: [SearchResult]) {
        let data = try await get("find/\(imdbId)", query: ["external_source": "imdb_id", "language": "en-US"], ttl: CacheTTL.providers)
        let r = try decode(FindResponse.self, data)
        return ((r.movieResults ?? []).map { $0.withKind(.movie) }, (r.tvResults ?? []).map { $0.withKind(.tv) })
    }

    /// movie details with release_dates appended in the same call
    public func movie(_ id: Int, ttl: TimeInterval = CacheTTL.details) async throws -> MovieDetails {
        let data = try await get("movie/\(id)", query: ["append_to_response": "release_dates", "language": "en-US"], ttl: ttl)
        return try decode(MovieDetails.self, data)
    }

    /// a tmdb collection (e.g. "Dune Collection") with its films
    public func collection(_ id: Int) async throws -> CollectionDetails {
        let data = try await get("collection/\(id)", query: ["language": "en-US"], ttl: CacheTTL.search)
        return try decode(CollectionDetails.self, data)
    }

    public func tv(_ id: Int, ttl: TimeInterval = CacheTTL.details) async throws -> TVDetails {
        let data = try await get("tv/\(id)", query: ["language": "en-US"], ttl: ttl)
        return try decode(TVDetails.self, data)
    }

    public func season(_ id: Int, _ season: Int, ttl: TimeInterval = CacheTTL.season) async throws -> SeasonDetails {
        let data = try await get("tv/\(id)/season/\(season)", query: ["language": "en-US"], ttl: ttl)
        return try decode(SeasonDetails.self, data)
    }

    /// watch providers for one region (justwatch data). nil when tmdb has nothing for the region.
    public func providers(_ type: MediaType, _ id: Int, region: String) async throws -> ProviderInfo? {
        let data = try await get("\(type.rawValue)/\(id)/watch/providers", ttl: CacheTTL.providers)
        return try decode(ProvidersResponse.self, data).results[region.uppercased()]
    }
}
