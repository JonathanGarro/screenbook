import Foundation

// series index

/// a film's position in its tmdb collection, compared with what the note has
public struct SeriesFinding: Sendable, Hashable {
    public var noteTitle: String
    public var collection: String
    public var current: Int?
    public var suggested: Int
    public var of: Int
    public var path: String
}

public struct SeriesAudit: Sendable {
    public var keysAdded: [String] = []
    public var toFill: [SeriesFinding] = []
    public var differs: [SeriesFinding] = []
    public var matching = 0
    public var notInCollection = 0
    public var filled: [String] = []
    public var errors: [String] = []
}

extension WatchlistService {
    /// release-order position of a movie in its tmdb collection, counting only released films
    public func seriesPosition(tmdbId: Int) async throws -> (collection: String, index: Int, of: Int)? {
        guard let client else { throw TMDBError.missingAPIKey }
        guard let ref = try await client.movie(tmdbId, ttl: CacheTTL.providers).belongsToCollection else { return nil }
        let parts = try await client.collection(ref.id).parts
            .filter { ($0.date ?? "9999") <= today }
            .sorted { ($0.date ?? "", $0.id) < ($1.date ?? "", $1.id) }
        guard parts.count >= 2, let i = parts.firstIndex(where: { $0.id == tmdbId }) else { return nil }
        let name = ref.name.hasSuffix(" Collection") ? String(ref.name.dropLast(" Collection".count)) : ref.name
        return (name, i + 1, parts.count)
    }

    /// adds a blank film_series_index to every movie and tv note missing it, and fills blank indexes from
    /// tmdb collections. filled values are never changed, only reported when they differ. dryRun writes nothing.
    public func auditSeries(dryRun: Bool = true, keysOnly: Bool = false, vault explicit: URL? = nil,
                            progress: ((Int, Int) -> Void)? = nil) async throws -> SeriesAudit {
        let vault = try vaultURL(explicit)
        var audit = SeriesAudit()
        let key = "film_series_index"

        // every note in the movie and tv folders gets the key
        for folder in [config.obsidianFilmFolder, config.obsidianTVFolder] where !folder.isEmpty {
            for url in NoteRename.vaultNotes(vault.appendingPathComponent(folder)) {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let updated = ObsidianNote.ensureProperty(text, key: key, after: "connected_to") else { continue }
                audit.keysAdded.append(url.deletingPathExtension().lastPathComponent)
                if !dryRun { try updated.write(to: url, atomically: true, encoding: .utf8) }
            }
        }

        if keysOnly { return audit }

        // compare each linked movie note with its collection
        let index = try noteIndex(vault: vault)
        let movies = try db.allReviews().filter { $0.mediaType == .movie && $0.isSent }
        for (i, r) in movies.enumerated() {
            progress?(i + 1, movies.count)
            guard let path = index[r.id] ?? r.exportPath else { continue }
            let url = vault.appendingPathComponent(path)
            do {
                guard let pos = try await seriesPosition(tmdbId: r.tmdbId) else { audit.notInCollection += 1; continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let raw = ObsidianNote.parse(text).properties.first { $0.key == key }.map { ObsidianNote.scalar($0.value) } ?? ""
                let current = Int(raw)
                let finding = SeriesFinding(noteTitle: url.deletingPathExtension().lastPathComponent, collection: pos.collection,
                                            current: current, suggested: pos.index, of: pos.of, path: path)
                if current == nil {
                    audit.toFill.append(finding)
                } else if current != pos.index {
                    audit.differs.append(finding)
                } else {
                    audit.matching += 1
                }
            } catch {
                audit.errors.append("\(r.noteTitle): \(error.localizedDescription)")
            }
        }
        audit.toFill.sort { ($0.collection, $0.suggested) < ($1.collection, $1.suggested) }
        audit.differs.sort { ($0.collection, $0.suggested) < ($1.collection, $1.suggested) }
        return audit
    }

    /// writes the suggested index into the chosen notes, only where the property is blank
    public func applySeries(_ findings: [SeriesFinding], vault explicit: URL? = nil) throws -> [String] {
        let vault = try vaultURL(explicit)
        var done: [String] = []
        for f in findings {
            let url = vault.appendingPathComponent(f.path)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let withKey = ObsidianNote.ensureProperty(text, key: "film_series_index", after: "connected_to") { text = withKey }
            let (out, changed) = ObsidianNote.setProperties(text, [("film_series_index", String(f.suggested))], overwrite: false)
            if !changed.isEmpty {
                try out.write(to: url, atomically: true, encoding: .utf8)
                done.append(f.noteTitle)
            }
        }
        return done
    }
}
