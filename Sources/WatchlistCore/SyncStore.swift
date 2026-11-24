import Foundation

// icloud sync, local side.
// only what you decided is synced: which titles you track, their watched, stopped and all episodes out
// state, and which episodes you watched. everything else (posters, air dates, seasons, providers) each
// device fetches from tmdb itself. triggers record every change in sync_outbox, whichever code path or
// process made it, and CloudSync sends the outbox to the private icloud database.

// schema

let syncSchemaSQL = """
create table if not exists sync_outbox (
    record_name text primary key,
    op text not null check (op in ('save', 'delete')),
    changed_at text not null
);
create table if not exists sync_system_fields (
    record_name text primary key,
    data text not null
);
-- each trigger deletes then inserts: an outer insert or ignore or upsert would override an or replace here
create trigger if not exists sync_title_insert after insert on titles
when (select value from meta where key = 'sync_applying') is null
begin
    delete from sync_outbox where record_name = 'title-' || new.media_type || '-' || new.tmdb_id;
    insert into sync_outbox values ('title-' || new.media_type || '-' || new.tmdb_id, 'save', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
end;
create trigger if not exists sync_title_update after update on titles
when (select value from meta where key = 'sync_applying') is null
    and (old.added_on is not new.added_on or old.watched_on is not new.watched_on
         or old.stopped_on is not new.stopped_on or old.all_available is not new.all_available)
begin
    delete from sync_outbox where record_name = 'title-' || new.media_type || '-' || new.tmdb_id;
    insert into sync_outbox values ('title-' || new.media_type || '-' || new.tmdb_id, 'save', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
end;
create trigger if not exists sync_title_delete after delete on titles
when (select value from meta where key = 'sync_applying') is null
begin
    delete from sync_outbox where record_name = 'title-' || old.media_type || '-' || old.tmdb_id;
    insert into sync_outbox values ('title-' || old.media_type || '-' || old.tmdb_id, 'delete', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
end;
create trigger if not exists sync_episode_insert after insert on watched_episodes
when (select value from meta where key = 'sync_applying') is null
begin
    delete from sync_outbox where record_name = 'ep-' || new.tmdb_id || '-' || new.season || '-' || new.episode;
    insert into sync_outbox values ('ep-' || new.tmdb_id || '-' || new.season || '-' || new.episode, 'save', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
end;
create trigger if not exists sync_episode_delete after delete on watched_episodes
when (select value from meta where key = 'sync_applying') is null
begin
    delete from sync_outbox where record_name = 'ep-' || old.tmdb_id || '-' || old.season || '-' || old.episode;
    insert into sync_outbox values ('ep-' || old.tmdb_id || '-' || old.season || '-' || old.episode, 'delete', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
end;
"""

// records

/// the synced part of a title, plus a few display fields so the other device can list it before tmdb answers
public struct SyncTitle: Equatable, Sendable {
    public var tmdbId: Int
    public var mediaType: MediaType
    public var title: String
    public var year: Int?
    public var posterPath: String?
    public var regionReleaseDate: String?
    public var addedOn: String
    public var watchedOn: String?
    public var stoppedOn: String?
    public var allAvailable: Bool
    /// when this state was last changed on any device; the newer change wins a conflict
    public var modifiedAt: String

    public init(tmdbId: Int, mediaType: MediaType, title: String, year: Int? = nil, posterPath: String? = nil,
                regionReleaseDate: String? = nil, addedOn: String, watchedOn: String? = nil, stoppedOn: String? = nil,
                allAvailable: Bool = false, modifiedAt: String) {
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.title = title
        self.year = year
        self.posterPath = posterPath
        self.regionReleaseDate = regionReleaseDate
        self.addedOn = addedOn
        self.watchedOn = watchedOn
        self.stoppedOn = stoppedOn
        self.allAvailable = allAvailable
        self.modifiedAt = modifiedAt
    }

    public var recordName: String { SyncName.title(tmdbId, mediaType) }
}

public struct SyncEpisode: Equatable, Sendable {
    public var tmdbId: Int
    public var season: Int
    public var episode: Int
    public var watchedOn: String?

    public init(tmdbId: Int, season: Int, episode: Int, watchedOn: String?) {
        self.tmdbId = tmdbId
        self.season = season
        self.episode = episode
        self.watchedOn = watchedOn
    }

    public var recordName: String { SyncName.episode(tmdbId, season, episode) }
}

public enum RemoteChange: Equatable, Sendable {
    case title(SyncTitle)
    case episode(SyncEpisode)
    case deleted(String)
}

public struct OutboxEntry: Equatable, Sendable {
    public var recordName: String
    public var isDelete: Bool
    public var changedAt: String
}

/// record names: title-tv-1396, title-movie-603, ep-1396-2-5
public enum SyncName {
    public enum Kind: Equatable { case title(Int, MediaType), episode(Int, Int, Int) }

    public static func title(_ id: Int, _ type: MediaType) -> String { "title-\(type.rawValue)-\(id)" }
    public static func episode(_ id: Int, _ season: Int, _ episode: Int) -> String { "ep-\(id)-\(season)-\(episode)" }

    public static func parse(_ name: String) -> Kind? {
        let parts = name.split(separator: "-").map(String.init)
        if parts.count == 3, parts[0] == "title", let type = MediaType(rawValue: parts[1]), let id = Int(parts[2]) {
            return .title(id, type)
        }
        if parts.count == 4, parts[0] == "ep", let id = Int(parts[1]), let s = Int(parts[2]), let e = Int(parts[3]) {
            return .episode(id, s, e)
        }
        return nil
    }

    /// seeded entries carry this time so anything already in icloud wins over them
    public static let seedTime = "2000-01-01T00:00:00.000Z"
}

// queries

extension Database {
    public func outbox() throws -> [OutboxEntry] {
        try query("select * from sync_outbox order by changed_at").map {
            OutboxEntry(recordName: $0.string("record_name") ?? "", isDelete: $0.string("op") == "delete",
                        changedAt: $0.string("changed_at") ?? "")
        }
    }

    public func outboxEntry(_ name: String) throws -> OutboxEntry? {
        try query("select * from sync_outbox where record_name = ?", [.text(name)]).first.map {
            OutboxEntry(recordName: name, isDelete: $0.string("op") == "delete", changedAt: $0.string("changed_at") ?? "")
        }
    }

    /// drops an outbox entry once it is in icloud, unless it changed again while being sent
    public func clearOutbox(_ name: String, sentAt: String? = nil) throws {
        if let sentAt {
            try execute("delete from sync_outbox where record_name = ? and changed_at <= ?", [.text(name), .text(sentAt)])
        } else {
            try execute("delete from sync_outbox where record_name = ?", [.text(name)])
        }
    }

    /// queues everything for upload, the first time sync runs or after a reset. never overwrites a real pending change.
    public func seedOutbox() throws {
        try transaction {
            try execute("""
                insert or ignore into sync_outbox (record_name, op, changed_at)
                select 'title-' || media_type || '-' || tmdb_id, 'save', ? from titles
                """, [.text(SyncName.seedTime)])
            try execute("""
                insert or ignore into sync_outbox (record_name, op, changed_at)
                select 'ep-' || tmdb_id || '-' || season || '-' || episode, 'save', ? from watched_episodes
                """, [.text(SyncName.seedTime)])
        }
    }

    public func syncTitle(_ id: Int, _ type: MediaType) throws -> SyncTitle? {
        guard let t = try title(tmdbId: id, mediaType: type) else { return nil }
        let changed = try outboxEntry(SyncName.title(id, type))?.changedAt ?? SyncName.seedTime
        return SyncTitle(tmdbId: t.tmdbId, mediaType: t.mediaType, title: t.title, year: t.year, posterPath: t.posterPath,
                         regionReleaseDate: t.regionReleaseDate, addedOn: t.addedOn, watchedOn: t.watchedOn,
                         stoppedOn: t.stoppedOn, allAvailable: t.allAvailable, modifiedAt: changed)
    }

    public func syncEpisode(_ id: Int, _ season: Int, _ episode: Int) throws -> SyncEpisode? {
        try query("select watched_on from watched_episodes where tmdb_id = ? and season = ? and episode = ?",
                  [.of(id), .of(season), .of(episode)]).first.map {
            SyncEpisode(tmdbId: id, season: season, episode: episode, watchedOn: $0.string("watched_on"))
        }
    }

    public func systemFields(_ name: String) throws -> Data? {
        try query("select data from sync_system_fields where record_name = ?", [.text(name)]).first?
            .string("data").flatMap { Data(base64Encoded: $0) }
    }

    public func setSystemFields(_ name: String, _ data: Data?) throws {
        if let data {
            try execute("insert or replace into sync_system_fields (record_name, data) values (?, ?)",
                        [.text(name), .text(data.base64EncodedString())])
        } else {
            try execute("delete from sync_system_fields where record_name = ?", [.text(name)])
        }
    }

    /// forgets everything icloud told us, for a signed out or switched account. local data stays.
    public func resetSyncState() throws {
        try transaction {
            try execute("delete from sync_system_fields")
            try execute("delete from sync_outbox")
            try setMeta("sync_state", nil)
            try setMeta("sync_seeded", nil)
        }
    }

    /// writes changes from another device without echoing them back to the outbox.
    /// a pending local change that is newer than the incoming one is kept, and sent next.
    /// returns the titles that arrived new, so the caller can fetch their details.
    @discardableResult
    public func applyRemote(_ changes: [RemoteChange], today: String) throws -> [Title] {
        var added: [Title] = []
        try transaction {
            try setMeta("sync_applying", "1")
            defer { try? setMeta("sync_applying", nil) }
            for change in changes {
                switch change {
                case .title(let r):
                    let pending = try outboxEntry(r.recordName)
                    if let pending, pending.changedAt > r.modifiedAt { continue }
                    if var t = try title(tmdbId: r.tmdbId, mediaType: r.mediaType) {
                        t.addedOn = r.addedOn
                        t.watchedOn = r.watchedOn
                        t.stoppedOn = r.stoppedOn
                        t.allAvailable = r.allAvailable
                        try upsertTitle(t)
                    } else {
                        var t = Title(tmdbId: r.tmdbId, mediaType: r.mediaType, title: r.title, addedOn: r.addedOn)
                        t.year = r.year
                        t.posterPath = r.posterPath
                        t.regionReleaseDate = r.regionReleaseDate
                        t.watchedOn = r.watchedOn
                        t.stoppedOn = r.stoppedOn
                        t.allAvailable = r.allAvailable
                        // a movie that is already out is not news on this device
                        t.releaseFlagged = r.regionReleaseDate.map { $0 <= today } ?? false
                        try upsertTitle(t)
                        added.append(t)
                    }
                    if pending != nil { try clearOutbox(r.recordName) }
                case .episode(let e):
                    if let pending = try outboxEntry(e.recordName), pending.isDelete { continue }
                    try execute("insert or ignore into watched_episodes (tmdb_id, season, episode, watched_on) values (?, ?, ?, ?)",
                                [.of(e.tmdbId), .of(e.season), .of(e.episode), .of(e.watchedOn)])
                    try clearOutbox(e.recordName)
                case .deleted(let name):
                    try setSystemFields(name, nil)
                    if let pending = try outboxEntry(name), !pending.isDelete { continue }
                    try clearOutbox(name)
                    switch SyncName.parse(name) {
                    case .title(let id, let type):
                        try execute("delete from titles where tmdb_id = ? and media_type = ?", [.of(id), .text(type.rawValue)])
                        if type == .tv {
                            try execute("delete from watched_episodes where tmdb_id = ?", [.of(id)])
                            try execute("delete from seasons where tmdb_id = ?", [.of(id)])
                        }
                    case .episode(let id, let s, let e):
                        try execute("delete from watched_episodes where tmdb_id = ? and season = ? and episode = ?",
                                    [.of(id), .of(s), .of(e)])
                    case nil:
                        break
                    }
                }
            }
        }
        return added
    }
}
