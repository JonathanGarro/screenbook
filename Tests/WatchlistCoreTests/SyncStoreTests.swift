import Foundation
import Testing
@testable import WatchlistCore

// icloud sync, local side

@Suite("sync outbox")
struct SyncOutboxTests {
    func show(_ id: Int = 1396) -> Title {
        Title(tmdbId: id, mediaType: .tv, title: "Breaking Bad", addedOn: "2026-01-01")
    }

    @Test func addingAndWatchingAreQueued() throws {
        let db = try Database.inMemory()
        try db.upsertTitle(show())
        try db.setWatched(tmdbId: 1396, [EpisodeRef(season: 1, episode: 1)], watched: true, on: "2026-01-02")
        let names = try db.outbox().map(\.recordName).sorted()
        #expect(names == ["ep-1396-1-1", "title-tv-1396"])
        let ops = try db.outbox(); #expect(ops.filter { $0.isDelete }.isEmpty)
    }

    @Test func metadataRefreshIsNotQueued() throws {
        let db = try Database.inMemory()
        var t = show()
        try db.upsertTitle(t)
        try db.clearOutbox("title-tv-1396")
        t.overview = "a chemistry teacher"
        t.nextAirDate = "2026-02-01"
        t.lastRefreshed = "2026-01-05T00:00:00Z"
        try db.upsertTitle(t)
        #expect(try db.outbox().isEmpty)
        t.stoppedOn = "2026-01-06"
        try db.upsertTitle(t)
        #expect(try db.outbox().map(\.recordName) == ["title-tv-1396"])
    }

    @Test func removingQueuesDeletes() throws {
        let db = try Database.inMemory()
        try db.upsertTitle(show())
        try db.setWatched(tmdbId: 1396, [EpisodeRef(season: 1, episode: 1)], watched: true, on: "2026-01-02")
        try db.deleteTitle(tmdbId: 1396, mediaType: .tv)
        let ops = try db.outbox()
        #expect(ops.count == 2)
        #expect(ops.filter { !$0.isDelete }.isEmpty)
    }

    @Test func seedKeepsRealChanges() throws {
        let db = try Database.inMemory()
        try db.upsertTitle(show())
        try db.upsertTitle(show(2000))
        try db.clearOutbox("title-tv-2000")
        try db.seedOutbox()
        let byName = Dictionary(uniqueKeysWithValues: try db.outbox().map { ($0.recordName, $0.changedAt) })
        #expect(byName["title-tv-2000"] == SyncName.seedTime)
        #expect(byName["title-tv-1396"] != SyncName.seedTime)
    }

    @Test func recordNamesRoundTrip() {
        #expect(SyncName.parse("title-movie-603") == .title(603, .movie))
        #expect(SyncName.parse("ep-1396-2-5") == .episode(1396, 2, 5))
        #expect(SyncName.parse("other") == nil)
    }
}

@Suite("sync apply")
struct SyncApplyTests {
    func remote(_ modified: String, watched: String? = nil) -> SyncTitle {
        SyncTitle(tmdbId: 603, mediaType: .movie, title: "The Matrix", year: 1999, regionReleaseDate: "1999-03-31",
                  addedOn: "2026-01-01", watchedOn: watched, modifiedAt: modified)
    }

    @Test func remoteChangesDoNotEcho() throws {
        let db = try Database.inMemory()
        let added = try db.applyRemote([
            .title(remote("2026-01-01T00:00:00.000Z")),
            .episode(SyncEpisode(tmdbId: 1396, season: 1, episode: 2, watchedOn: "2026-01-03")),
        ], today: "2026-02-01")
        #expect(added.map(\.tmdbId) == [603])
        #expect(try db.outbox().isEmpty)
        #expect(try db.title(tmdbId: 603, mediaType: .movie)?.releaseFlagged == true)
        #expect(try db.watched(tmdbId: 1396) == [EpisodeRef(season: 1, episode: 2)])
        // the trigger works again afterwards
        try db.setWatched(tmdbId: 1396, [EpisodeRef(season: 1, episode: 3)], watched: true, on: "2026-01-04")
        #expect(try db.outbox().map(\.recordName) == ["ep-1396-1-3"])
    }

    @Test func remoteUpdateKeepsLocalDetails() throws {
        let db = try Database.inMemory()
        var t = Title(tmdbId: 603, mediaType: .movie, title: "The Matrix", addedOn: "2026-01-01")
        t.overview = "red pill"
        try db.upsertTitle(t)
        try db.clearOutbox("title-movie-603")
        try db.applyRemote([.title(remote("2026-03-01T00:00:00.000Z", watched: "2026-03-01"))], today: "2026-03-02")
        let after = try db.title(tmdbId: 603, mediaType: .movie)
        #expect(after?.watchedOn == "2026-03-01")
        #expect(after?.overview == "red pill")
    }

    @Test func newerLocalChangeWins() throws {
        let db = try Database.inMemory()
        var t = Title(tmdbId: 603, mediaType: .movie, title: "The Matrix", addedOn: "2026-01-01")
        t.watchedOn = "2026-05-01"
        try db.upsertTitle(t)
        try db.applyRemote([.title(remote("2001-01-01T00:00:00.000Z"))], today: "2026-05-02")
        #expect(try db.title(tmdbId: 603, mediaType: .movie)?.watchedOn == "2026-05-01")
        #expect(try db.outbox().map(\.recordName) == ["title-movie-603"])
    }

    @Test func olderLocalChangeLoses() throws {
        let db = try Database.inMemory()
        try db.upsertTitle(Title(tmdbId: 603, mediaType: .movie, title: "The Matrix", addedOn: "2026-01-01"))
        try db.applyRemote([.title(remote("2999-01-01T00:00:00.000Z", watched: "2026-06-01"))], today: "2026-06-02")
        #expect(try db.title(tmdbId: 603, mediaType: .movie)?.watchedOn == "2026-06-01")
        #expect(try db.outbox().isEmpty)
    }

    @Test func remoteDeleteRemovesShowAndEpisodes() throws {
        let db = try Database.inMemory()
        try db.applyRemote([
            .title(SyncTitle(tmdbId: 1396, mediaType: .tv, title: "Breaking Bad", addedOn: "2026-01-01", modifiedAt: "2026-01-01T00:00:00.000Z")),
            .episode(SyncEpisode(tmdbId: 1396, season: 1, episode: 1, watchedOn: nil)),
        ], today: "2026-01-02")
        try db.applyRemote([.deleted("title-tv-1396")], today: "2026-01-03")
        #expect(try db.title(tmdbId: 1396, mediaType: .tv) == nil)
        #expect(try db.watched(tmdbId: 1396).isEmpty)
        #expect(try db.outbox().isEmpty)
    }

    @Test func pendingUnwatchIsNotUndone() throws {
        let db = try Database.inMemory()
        try db.applyRemote([.episode(SyncEpisode(tmdbId: 1, season: 1, episode: 1, watchedOn: nil))], today: "2026-01-01")
        try db.setWatched(tmdbId: 1, [EpisodeRef(season: 1, episode: 1)], watched: false, on: "2026-01-02")
        try db.applyRemote([.episode(SyncEpisode(tmdbId: 1, season: 1, episode: 1, watchedOn: nil))], today: "2026-01-02")
        #expect(try db.watched(tmdbId: 1).isEmpty)
    }
}
