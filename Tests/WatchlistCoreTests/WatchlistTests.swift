import Foundation
import Testing
@testable import WatchlistCore

// mock transport

/// answers requests from canned json keyed by url path. no network is touched.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var routes: [String: [(Int, String)]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ path: String, status: Int = 200, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        routes["/3/" + path, default: []].append((status, body))
    }

    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == "/3/" + path }.count
    }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let path = request.url!.path
        guard var queue = routes[path], !queue.isEmpty else {
            let r = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"status_message":"not mocked"}"#.utf8), r)
        }
        // the last response repeats so a route can be hit more than once
        let (status, body) = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[path] = queue
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                headerFields: status == 429 ? ["Retry-After": "0"] : nil)!
        return (Data(body.utf8), r)
    }
}

final class Clock: @unchecked Sendable {
    var date: Date
    init(_ day: String) { date = Clock.parse(day) }
    static func parse(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: day + " 12:00")!
    }
    func set(_ day: String) { date = Clock.parse(day) }
}

// fixtures

enum Fixture {
    static func movie(id: Int = 100, release usDate: String, digital: String? = nil, primary: String = "2026-01-01") -> String {
        var us = #"{"certification":"PG-13","note":"","release_date":"\#(usDate)T00:00:00.000Z","type":3}"#
        if let digital {
            us += #",{"certification":"","note":"","release_date":"\#(digital)T00:00:00.000Z","type":4}"#
        }
        return """
        {"id":\(id),"title":"Test Movie","release_date":"\(primary)","status":"Post Production","overview":"x","poster_path":"/p.jpg",
         "release_dates":{"results":[
           {"iso_3166_1":"GB","release_dates":[{"certification":"","note":"","release_date":"2025-12-01T00:00:00.000Z","type":3}]},
           {"iso_3166_1":"US","release_dates":[\(us)]}
         ]}}
        """
    }

    static func tv(id: Int = 200, last: (Int, Int, String)?, next: (Int, Int, String)?, seasons: [(Int, Int)]) -> String {
        func ep(_ e: (Int, Int, String)?) -> String {
            guard let e else { return "null" }
            return #"{"air_date":"\#(e.2)","episode_number":\#(e.1),"season_number":\#(e.0),"name":"Ep"}"#
        }
        let seasonJSON = seasons.map { #"{"season_number":\#($0.0),"episode_count":\#($0.1),"air_date":"2020-01-01","name":"Season \#($0.0)"}"# }
            .joined(separator: ",")
        return """
        {"id":\(id),"name":"Test Show","first_air_date":"2020-01-01","status":"Returning Series","in_production":true,
         "number_of_seasons":\(seasons.count),"overview":"y","poster_path":"/s.jpg",
         "seasons":[\(seasonJSON)],"last_episode_to_air":\(ep(last)),"next_episode_to_air":\(ep(next))}
        """
    }

    static let search = """
    {"page":1,"results":[
      {"id":100,"media_type":"movie","title":"Test Movie","release_date":"2026-03-01","overview":"x","poster_path":null},
      {"id":7,"media_type":"person","name":"Someone"},
      {"id":200,"media_type":"tv","name":"Test Show","first_air_date":"2020-01-01","overview":"y"}
    ],"total_pages":1,"total_results":3}
    """

    static let providers = """
    {"id":200,"results":{
      "US":{"link":"https://www.themoviedb.org/tv/200/watch?locale=US",
            "flatrate":[{"logo_path":"/b.jpg","provider_id":2,"provider_name":"Beta Stream","display_priority":5},
                        {"logo_path":"/a.jpg","provider_id":1,"provider_name":"Alpha Plus","display_priority":1}],
            "rent":[{"logo_path":"/r.jpg","provider_id":3,"provider_name":"Rent Store","display_priority":2}]},
      "GB":{"link":"x","flatrate":[{"logo_path":"/c.jpg","provider_id":9,"provider_name":"UK Only","display_priority":1}]}
    }}
    """
}

func makeService(_ mock: MockTransport, _ clock: Clock, config: AppConfig = AppConfig()) throws -> WatchlistService {
    let db = try Database.inMemory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watchlist-tests-\(UUID().uuidString)")
    let client = TMDBClient(apiKey: "test-key", db: db, transport: mock, minInterval: 0, backoffBase: 0, now: { clock.date })
    return WatchlistService(db: db, paths: AppPaths(dataDir: dir), config: config, client: client, now: { clock.date })
}

// release dates

@Suite struct ReleasePickerTests {
    func dates(_ json: String) throws -> ReleaseDates {
        try TMDBClient.decoder().decode(MovieDetails.self, from: Data(json.utf8)).releaseDates!
    }

    @Test func picksRegionTheatricalOverOtherCountries() throws {
        let rd = try dates(Fixture.movie(release: "2026-03-06", digital: "2026-04-01"))
        let us = ReleasePicker.pick(rd, region: "US", fallback: "2026-01-01")
        #expect(us.release == "2026-03-06")
        #expect(us.digital == "2026-04-01")
        let gb = ReleasePicker.pick(rd, region: "gb", fallback: nil)
        #expect(gb.release == "2025-12-01")
    }

    @Test func fallsBackToPrimaryWhenRegionMissing() throws {
        let rd = try dates(Fixture.movie(release: "2026-03-06"))
        #expect(ReleasePicker.pick(rd, region: "JP", fallback: "2026-01-01").release == "2026-01-01")
        #expect(ReleasePicker.pick(nil, region: "US", fallback: "").release == nil)
    }

    @Test func usesDigitalWhenNoTheatrical() throws {
        let json = """
        {"results":[{"iso_3166_1":"US","release_dates":[
          {"release_date":"2026-05-01T00:00:00.000Z","type":4},
          {"release_date":"2026-02-01T00:00:00.000Z","type":1}]}]}
        """
        let rd = try TMDBClient.decoder().decode(ReleaseDates.self, from: Data(json.utf8))
        #expect(ReleasePicker.pick(rd, region: "US", fallback: nil).release == "2026-05-01")
    }
}

// episode math

@Suite struct EpisodeMathTests {
    let seasons = [SeasonSummary(seasonNumber: 0, episodeCount: 3),
                   SeasonSummary(seasonNumber: 1, episodeCount: 3),
                   SeasonSummary(seasonNumber: 2, episodeCount: 8)]

    @Test func airedSkipsSpecialsAndFutureEpisodes() {
        let aired = EpisodeMath.aired(seasons: seasons, lastAired: EpisodeRef(season: 2, episode: 2))
        #expect(aired.count == 5)
        #expect(aired.first == EpisodeRef(season: 1, episode: 1))
        #expect(aired.last == EpisodeRef(season: 2, episode: 2))
    }

    @Test func noLastAiredMeansNothingAired() {
        #expect(EpisodeMath.aired(seasons: seasons, lastAired: nil).isEmpty)
    }

    @Test func upToCoversEarlierSeasons() {
        let list = EpisodeMath.upTo(EpisodeRef(season: 2, episode: 4), seasons: seasons)
        #expect(list.count == 7)
        #expect(!list.contains { $0.season == 0 })
    }

    @Test func episodeCodeFormat() {
        #expect(EpisodeRef(season: 1, episode: 9).code == "S01E09")
    }
}

// client

@Suite struct ClientTests {
    @Test func cachesResponsesWithinTTL() async throws {
        let mock = MockTransport()
        let clock = Clock("2026-02-01")
        mock.on("tv/200", Fixture.tv(last: (1, 1, "2026-01-01"), next: nil, seasons: [(1, 3)]))
        let service = try makeService(mock, clock)
        _ = try await service.client!.tv(200)
        _ = try await service.client!.tv(200)
        #expect(mock.count("tv/200") == 1)
        clock.date = clock.date.addingTimeInterval(CacheTTL.details + 1)
        _ = try await service.client!.tv(200)
        #expect(mock.count("tv/200") == 2)
    }

    @Test func retriesAfter429() async throws {
        let mock = MockTransport()
        mock.on("tv/200", status: 429, "{}")
        mock.on("tv/200", Fixture.tv(last: nil, next: nil, seasons: []))
        let service = try makeService(mock, Clock("2026-02-01"))
        let show = try await service.client!.tv(200)
        #expect(show.name == "Test Show")
        #expect(mock.count("tv/200") == 2)
    }

    @Test func surfacesBadKey() async throws {
        let mock = MockTransport()
        mock.on("tv/200", status: 401, #"{"status_code":7,"status_message":"Invalid API key"}"#)
        let service = try makeService(mock, Clock("2026-02-01"))
        await #expect(throws: TMDBError.http(401, "Invalid API key")) {
            _ = try await service.client!.tv(200)
        }
    }

    @Test func sendsKeyAsQueryOrBearer() async throws {
        let mock = MockTransport()
        mock.on("search/multi", Fixture.search)
        let service = try makeService(mock, Clock("2026-02-01"))
        let results = try await service.search("test")
        #expect(results.map(\.id) == [100, 200])
        #expect(mock.requests[0].url!.query!.contains("api_key=test-key"))

        let db = try Database.inMemory()
        let bearer = TMDBClient(apiKey: "eyJhbGciOi.token", db: db, transport: mock, minInterval: 0)
        _ = try await bearer.search("test")
        let last = mock.requests.last!
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer eyJhbGciOi.token")
        #expect(!(last.url!.query ?? "").contains("api_key"))
    }

    @Test func providersForRegionOnly() async throws {
        let mock = MockTransport()
        mock.on("tv/200/watch/providers", Fixture.providers)
        let service = try makeService(mock, Clock("2026-02-01"))
        let info = try await service.client!.providers(.tv, 200, region: "US")
        #expect(info?.names(includeRentBuy: false) == ["Alpha Plus", "Beta Stream"])
        #expect(info?.names(includeRentBuy: true).last == "Rent Store (rent)")
        let none = try await service.client!.providers(.tv, 200, region: "FR")
        #expect(none == nil)
        #expect(mock.count("tv/200/watch/providers") == 1)
    }
}

// service flows

@Suite struct ServiceTests {
    @Test func movieReleaseFlaggedOnceWhenDateArrives() async throws {
        let mock = MockTransport()
        let clock = Clock("2026-03-01")
        mock.on("movie/100", Fixture.movie(release: "2026-03-06"))
        let service = try makeService(mock, clock)
        let added = try await service.add(SearchResult(id: 100, mediaType: "movie", title: "Test Movie"))
        #expect(added.regionReleaseDate == "2026-03-06")
        #expect(!added.releaseFlagged)

        var report = try await service.check(force: true)
        #expect(report.releasedMovies.isEmpty)
        #expect(report.upcomingMovies.count == 1)

        clock.set("2026-03-07")
        report = try await service.check(force: true)
        #expect(report.releasedMovies.map(\.tmdbId) == [100])

        clock.set("2026-03-08")
        report = try await service.check(force: true)
        #expect(report.releasedMovies.isEmpty)
    }

    @Test func alreadyReleasedMovieIsNotReportedAsNew() async throws {
        let mock = MockTransport()
        mock.on("movie/100", Fixture.movie(release: "2025-06-01"))
        let service = try makeService(mock, Clock("2026-03-01"))
        try await service.add(SearchResult(id: 100, mediaType: "movie"))
        let report = try await service.check(force: true)
        #expect(report.releasedMovies.isEmpty)
    }

    @Test func newEpisodesSinceLastCheckRespectWatched() async throws {
        let mock = MockTransport()
        let clock = Clock("2026-02-01")
        mock.on("tv/200", Fixture.tv(last: (1, 2, "2026-01-25"), next: (1, 3, "2026-02-08"), seasons: [(1, 8)]))
        let service = try makeService(mock, clock)
        let show = try await service.add(SearchResult(id: 200, mediaType: "tv", name: "Test Show"), caughtUp: true)
        #expect(try service.unwatchedAired(show).isEmpty)

        var report = try await service.check(force: true)
        #expect(report.showsWithUnwatched.isEmpty)
        #expect(report.upcomingEpisodes.count == 1)

        // a week later episode 3 has aired
        clock.set("2026-02-09")
        mock.routes["/3/tv/200"] = [(200, Fixture.tv(last: (1, 3, "2026-02-08"), next: (1, 4, "2026-02-15"), seasons: [(1, 8)]))]
        report = try await service.check(force: true)
        #expect(report.newEpisodeShows.count == 1)
        #expect(report.newEpisodeShows[0].newlyAired == [EpisodeRef(season: 1, episode: 3)])

        // watching it clears the unwatched list; the next check reports nothing new
        try service.setWatched(200, season: 1, episode: 3)
        report = try await service.check(force: true)
        #expect(report.showsWithUnwatched.isEmpty)
        #expect(!report.hasNews)
    }

    @Test func notCaughtUpShowsBacklogButNothingNew() async throws {
        let mock = MockTransport()
        mock.on("tv/200", Fixture.tv(last: (2, 3, "2026-01-25"), next: nil, seasons: [(1, 10), (2, 10)]))
        let service = try makeService(mock, Clock("2026-02-01"))
        try await service.add(SearchResult(id: 200, mediaType: "tv"))
        let report = try await service.check(force: true)
        #expect(report.showsWithUnwatched.first?.unwatchedCount == 13)
        #expect(report.showsWithUnwatched.first?.firstUnwatched == EpisodeRef(season: 1, episode: 1))
        #expect(report.newEpisodeShows.isEmpty)
    }

    @Test func watchAllUpTo() async throws {
        let mock = MockTransport()
        mock.on("tv/200", Fixture.tv(last: (2, 5, "2026-01-25"), next: nil, seasons: [(0, 2), (1, 10), (2, 10)]))
        let service = try makeService(mock, Clock("2026-02-01"))
        let show = try await service.add(SearchResult(id: 200, mediaType: "tv"))
        let n = try await service.markAllUpTo(200, season: 2, episode: 2)
        #expect(n == 12)
        #expect(try service.unwatchedAired(show).map(\.code) == ["S02E03", "S02E04", "S02E05"])
    }

    @Test func removeAndAmbiguousIds() async throws {
        let mock = MockTransport()
        mock.on("movie/100", Fixture.movie(id: 100, release: "2026-03-06"))
        mock.on("tv/100", Fixture.tv(id: 100, last: (1, 1, "2026-01-01"), next: nil, seasons: [(1, 1)]))
        let service = try makeService(mock, Clock("2026-02-01"))
        try await service.add(SearchResult(id: 100, mediaType: "movie"))
        try await service.add(SearchResult(id: 100, mediaType: "tv"), caughtUp: true)
        #expect(throws: WatchlistError.self) { try service.remove(100) }
        try service.remove(100, .tv)
        #expect(try service.titles().map(\.mediaType) == [.movie])
        #expect(try service.db.watched(tmdbId: 100).isEmpty)
        #expect(throws: WatchlistError.self) { try service.remove(999) }
    }

    @Test func checkKeepsGoingWhenOneTitleFails() async throws {
        let mock = MockTransport()
        mock.on("movie/100", Fixture.movie(release: "2026-03-06"))
        mock.on("tv/200", Fixture.tv(last: (1, 1, "2026-01-01"), next: nil, seasons: [(1, 1)]))
        let service = try makeService(mock, Clock("2026-02-10"))
        try await service.add(SearchResult(id: 100, mediaType: "movie"))
        try await service.add(SearchResult(id: 200, mediaType: "tv"))
        mock.routes["/3/tv/200"] = [(500, #"{"status_message":"boom"}"#)]
        let report = try await service.check(force: true)
        #expect(report.errors.count == 1)
        #expect(report.upcomingMovies.count == 1)
        #expect(service.lastReport?.errors.count == 1)
    }
}

// outputs

@Suite struct OutputTests {
    @Test func digestWritesMarkdownWithAttribution() async throws {
        let mock = MockTransport()
        let clock = Clock("2026-03-01")
        mock.on("movie/100", Fixture.movie(release: "2026-03-06"))
        mock.on("tv/200", Fixture.tv(last: (1, 2, "2026-02-25"), next: nil, seasons: [(1, 8)]))
        mock.on("movie/100/watch/providers", #"{"id":100,"results":{}}"#)
        mock.on("tv/200/watch/providers", Fixture.providers)
        let service = try makeService(mock, clock, config: AppConfig(region: "US", streamingEnabled: true))
        try await service.add(SearchResult(id: 100, mediaType: "movie"))
        try await service.add(SearchResult(id: 200, mediaType: "tv"))
        clock.set("2026-03-07")
        let report = try await service.check(force: true)
        let (url, text) = try service.writeDigest(report)

        #expect(url.lastPathComponent == "digest.md")
        #expect(url.deletingLastPathComponent().lastPathComponent == "outputs")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(text.contains("| Test Movie | 2026 | 2026-03-06 | - |"))
        #expect(text.contains("Alpha Plus, Beta Stream"))
        #expect(text.contains("TMDB"))
        #expect(text.contains("JustWatch"))
        #expect(!text.contains("\u{2014}"))
    }

    @Test func digestOmitsJustWatchWhenStreamingOff() {
        let r = CheckReport(checkedAt: Date(), previousCheck: nil)
        let text = Digest.markdown(r, config: AppConfig())
        #expect(text.contains("None. You are caught up."))
        #expect(!text.contains("JustWatch"))
    }

    @Test func csvEscapesFields() {
        let csv = TextTable.csv(header: ["a", "b"], rows: [["x, y", "say \"hi\""]])
        #expect(csv == "a,b\n\"x, y\",\"say \"\"hi\"\"\"\n")
    }

    @Test func envParsing() {
        let parsed = APIKeyStore.parseEnv("# comment\nexport TMDB_API_KEY=\"abc123\"\nOTHER=1\n")
        #expect(parsed["TMDB_API_KEY"] == "abc123")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-env-\(UUID().uuidString)")
        let paths = AppPaths(dataDir: dir)
        #expect(APIKeyStore.resolve(paths, environment: [:]) == nil)
        #expect(APIKeyStore.resolve(paths, environment: ["TMDB_API_KEY": "fromenv"]) == "fromenv")
        try? APIKeyStore.save("saved-key", paths)
        #expect(APIKeyStore.resolve(paths, environment: [:]) == "saved-key")
    }
}
