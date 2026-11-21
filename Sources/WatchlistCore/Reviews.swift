import Foundation

// external ratings

/// imdb, metascore, and rotten tomatoes values from omdb, in the string forms the notes use
public struct ExternalRatings: Codable, Equatable, Sendable {
    public var imdbRating: String?
    public var imdbVotes: String?
    public var metascore: String?
    public var rottenTomatoes: String?

    public init(imdbRating: String? = nil, imdbVotes: String? = nil, metascore: String? = nil, rottenTomatoes: String? = nil) {
        self.imdbRating = imdbRating
        self.imdbVotes = imdbVotes
        self.metascore = metascore
        self.rottenTomatoes = rottenTomatoes
    }
}

/// optional omdb lookup (https://www.omdbapi.com) keyed by imdb id. results cached for 30 days.
public actor OMDbClient {
    private let apiKey: String
    private let db: Database
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(apiKey: String, db: Database, transport: HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.apiKey = apiKey
        self.db = db
        self.transport = transport
        self.now = now
    }

    private struct Response: Decodable {
        struct Source: Decodable {
            let Source: String
            let Value: String
        }
        let Response: String?
        let imdbRating: String?
        let imdbVotes: String?
        let Metascore: String?
        let Ratings: [Source]?
    }

    public func ratings(imdbId: String) async throws -> ExternalRatings? {
        let key = "omdb/\(imdbId)"
        var data: Data
        if let cached = try? db.cacheGet(key), now().timeIntervalSince(cached.fetchedAt) < CacheTTL.providers {
            data = Data(cached.body.utf8)
        } else {
            var c = URLComponents(string: "https://www.omdbapi.com/")!
            c.queryItems = [URLQueryItem(name: "i", value: imdbId), URLQueryItem(name: "apikey", value: apiKey)]
            let (body, response) = try await transport.get(URLRequest(url: c.url!))
            guard response.statusCode == 200 else { throw TMDBError.http(response.statusCode, "OMDb request failed") }
            data = body
            if let text = String(data: body, encoding: .utf8) { try? db.cachePut(key, body: text, at: now()) }
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard r.Response == "True" else { return nil }
        func clean(_ s: String?) -> String? { (s == nil || s == "N/A" || s!.isEmpty) ? nil : s }
        return ExternalRatings(imdbRating: clean(r.imdbRating), imdbVotes: clean(r.imdbVotes), metascore: clean(r.Metascore),
                               rottenTomatoes: clean(r.Ratings?.first { $0.Source == "Rotten Tomatoes" }?.Value))
    }
}

// vault

public enum ObsidianVault {
    /// the vault obsidian lists as open, else the first one, from obsidian's own config
    public static func detect() -> URL? {
        let config = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let entries = vaults.values.compactMap { v -> (String, Bool, Double)? in
            guard let path = v["path"] as? String else { return nil }
            return (path, (v["open"] as? Bool) ?? false, (v["ts"] as? Double) ?? 0)
        }
        let pick = entries.first { $0.1 } ?? entries.max { $0.2 < $1.2 }
        return pick.map { URL(fileURLWithPath: $0.0) }
    }

    public static func resolve(_ config: AppConfig) -> URL? {
        let path = config.obsidianVaultPath.trimmingCharacters(in: .whitespaces)
        if !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return detect()
    }

    /// obsidian://open link for a note inside the vault
    public static func openURL(vault: URL, relativePath: String) -> URL? {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: vault.lastPathComponent),
                        URLQueryItem(name: "file", value: relativePath)]
        return c.url
    }
}

// note formatting

public enum ObsidianNote {
    /// 4.5 becomes "★★★★½"
    public static func stars(_ rating: Double?) -> String {
        guard let rating, rating > 0 else { return "" }
        let halves = Int((rating * 2).rounded())
        return String(repeating: "★", count: halves / 2) + (halves % 2 == 1 ? "½" : "")
    }

    /// 4.0 becomes "4", 4.5 stays "4.5"
    public static func number(_ rating: Double) -> String {
        rating == rating.rounded() ? String(Int(rating)) : String(format: "%.1f", rating)
    }

    /// matches the vault habit of "Alien - Romulus" for "Alien: Romulus"
    public static func filename(_ title: String) -> String {
        var s = title.replacingOccurrences(of: ": ", with: " - ")
            .replacingOccurrences(of: ":", with: " -")
        for bad in ["/", "\\", "?", "*", "\"", "<", ">", "|", "#", "^", "[", "]"] {
            s = s.replacingOccurrences(of: bad, with: bad == "/" || bad == "\\" ? "-" : "")
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Untitled" : s
    }

    /// double-quotes values yaml would otherwise misread
    static func yaml(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let special = CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")
        if value.rangeOfCharacter(from: special) != nil || value.hasPrefix(" ") || value.hasSuffix(" ") {
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return value
    }

    static func line(_ key: String, _ value: String) -> String {
        value.isEmpty ? "\(key):" : "\(key): \(value)"
    }

    /// rating out of 5 times 20, minus the rotten tomatoes percentage
    public static func ratingDelta(rating: Double?, rottenTomatoes: String?) -> Int? {
        guard let rating, let rt = rottenTomatoes, let pct = Int(rt.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        return Int((rating * 20).rounded()) - pct
    }

    public static func wikiLink(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name.hasPrefix("[[") ? name : "[[\(name)]]"
    }

    public static func markdown(_ r: Review, imdbId: String? = nil, ratings: ExternalRatings? = nil) -> String {
        var fm: [String] = ["---"]
        fm.append(line("type", r.mediaType == .movie ? "Film" : "Television"))
        fm.append(line("rating", r.rating.map(number) ?? ""))
        fm.append(line("stars", stars(r.rating)))
        fm.append(line("finished_on", r.finishedOn ?? ""))
        fm.append(line("connected_to", yaml(wikiLink(r.connectedTo))))
        fm.append(line("film_series_index", r.seriesIndex.map(String.init) ?? ""))
        fm.append(line("rewatch", r.rewatch ? "true" : "false"))
        if r.mediaType == .movie {
            fm.append(line("imdb_id", imdbId ?? ""))
            fm.append(line("imdb_link", imdbId.map { "https://www.imdb.com/title/\($0)/" } ?? ""))
            fm.append(line("imdb_rating", ratings?.imdbRating.map { "'\($0)'" } ?? ""))
            fm.append(line("imdb_votes", ratings?.imdbVotes ?? ""))
            fm.append(line("metascore", ratings?.metascore.map { "'\($0)'" } ?? ""))
            fm.append(line("rotten_tomatoes", ratings?.rottenTomatoes ?? ""))
            fm.append(line("my_rating_delta", ratingDelta(rating: r.rating, rottenTomatoes: ratings?.rottenTomatoes).map(String.init) ?? ""))
        }
        fm.append(line(idKey, r.id))
        fm.append("---")
        let body = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.joined(separator: "\n") + "\n# \(r.noteTitle)\n\n" + (body.isEmpty ? "" : body + "\n")
    }

    public static func relativePath(_ r: Review, config: AppConfig) -> String {
        let folder = (r.mediaType == .movie ? config.obsidianFilmFolder : config.obsidianTVFolder)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let file = filename(r.noteTitle) + ".md"
        return folder.isEmpty ? file : "\(folder)/\(file)"
    }

    /// frontmatter key that ties a note to its watchlist review, so renames and moves do not break links
    public static let idKey = "watchlist_id"

    /// reads watchlist_id from a note's frontmatter
    public static func noteId(in text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        for raw in text.components(separatedBy: "\n").dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            if line.hasPrefix("\(idKey):") {
                let v = line.dropFirst(idKey.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func head(_ url: URL, bytes: Int = 4096) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// finds the note carrying this id, searching the given folders first and then the whole vault.
    /// hidden folders such as .obsidian and .trash are skipped. returns a vault-relative path.
    public static func find(id: String, vault: URL, preferring folders: [String] = []) -> String? {
        let fm = FileManager.default
        let roots = folders.filter { !$0.isEmpty }.map { vault.appendingPathComponent($0) } + [vault]
        var checked = Set<String>()
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where url.pathExtension.lowercased() == "md" {
                guard checked.insert(url.path).inserted else { continue }
                if let text = head(url), noteId(in: text) == id {
                    return relative(url, to: vault)
                }
            }
        }
        return nil
    }

    public static func relative(_ url: URL, to vault: URL) -> String? {
        let base = vault.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    /// adds or replaces watchlist_id in an existing note's frontmatter, leaving everything else alone
    public static func stampId(_ id: String, into url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            if let existing = lines[1..<close].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(idKey):") }) {
                lines[existing] = "\(idKey): \(id)"
            } else {
                lines.insert("\(idKey): \(id)", at: close)
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } else {
            try ("---\n\(idKey): \(id)\n---\n" + text).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// minimal show index note in the vault's existing style
    public static func indexNote(name: String) -> String {
        "---\ntype: Television\n---\n# \(name)\n"
    }
}

// errors

public enum ReviewError: Error, LocalizedError, Equatable {
    case noVault
    case vaultMissing(String)
    case noteExists(path: String, editedSince: Bool)
    case noteNotFound
    case outsideVault

    public var errorDescription: String? {
        switch self {
        case .noVault:
            return "No Obsidian vault found. Choose one in Settings, Obsidian."
        case .vaultMissing(let p):
            return "The Obsidian vault folder does not exist: \(p)"
        case .noteNotFound:
            return "Could not find this review's note in the vault. Use Locate Note to link it."
        case .outsideVault:
            return "That file is not inside the Obsidian vault."
        case .noteExists(let path, let edited):
            return edited
                ? "\(path) was edited in Obsidian after Watchlist sent it."
                : "A note already exists at \(path)."
        }
    }
}

// service

extension WatchlistService {
    public func reviews() throws -> [Review] {
        try db.allReviews()
    }

    /// a saved review, or a new draft with sensible defaults
    public func review(for t: Title, season: Int = 0) throws -> Review {
        let s = t.mediaType == .movie ? 0 : season
        if let existing = try db.review(tmdbId: t.tmdbId, mediaType: t.mediaType, season: s) {
            return existing
        }
        switch t.mediaType {
        case .movie:
            return Review(tmdbId: t.tmdbId, mediaType: .movie, noteTitle: t.title,
                          finishedOn: t.watchedOn ?? today)
        case .tv:
            return Review(tmdbId: t.tmdbId, mediaType: .tv, season: s, noteTitle: "\(t.title) - Season \(s)",
                          finishedOn: try db.lastWatchedDay(tmdbId: t.tmdbId, season: s) ?? today,
                          connectedTo: ObsidianNote.filename(t.title))
        }
    }

    public func saveReview(_ r: Review) throws {
        var r = r
        r.updatedAt = DateText.timestamp(now())
        try db.upsertReview(r)
    }

    public func deleteReview(_ r: Review) throws {
        try db.deleteReview(tmdbId: r.tmdbId, mediaType: r.mediaType, season: r.season)
    }

    /// sets or clears the watched day for a movie
    public func setMovieWatched(_ t: Title, on day: String?) throws {
        guard var current = try db.title(tmdbId: t.tmdbId, mediaType: t.mediaType) else { throw WatchlistError.notFound(t.tmdbId) }
        current.watchedOn = day
        try db.upsertTitle(current)
    }

    public var omdbClient: OMDbClient? {
        APIKeyStore.resolve(paths, name: APIKeyStore.omdbVariableName).map { OMDbClient(apiKey: $0, db: db) }
    }

    func vaultURL(_ explicit: URL? = nil) throws -> URL {
        guard let vault = explicit ?? ObsidianVault.resolve(config) else { throw ReviewError.noVault }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw ReviewError.vaultMissing(vault.path)
        }
        return vault
    }

    /// where the review's note is now: found by watchlist_id, else the recorded path if that file has no other id
    public func locateNote(_ r: Review, vault explicit: URL? = nil) throws -> String? {
        let vault = try vaultURL(explicit)
        let folder = r.mediaType == .movie ? config.obsidianFilmFolder : config.obsidianTVFolder
        if let path = r.exportPath {
            let url = vault.appendingPathComponent(path)
            if let text = ObsidianNote.head(url), ObsidianNote.noteId(in: text) == r.id { return path }
        }
        if let found = ObsidianNote.find(id: r.id, vault: vault, preferring: [folder]) { return found }
        if let path = r.exportPath {
            let url = vault.appendingPathComponent(path)
            if let text = ObsidianNote.head(url), ObsidianNote.noteId(in: text) == nil { return path }
        }
        return nil
    }

    /// finds the note, records its current path and title, and returns an obsidian:// link to it
    public func openURL(for r: Review, vault explicit: URL? = nil) throws -> (url: URL, review: Review) {
        let vault = try vaultURL(explicit)
        guard let path = try locateNote(r, vault: vault) else { throw ReviewError.noteNotFound }
        var updated = r
        if path != r.exportPath {
            updated.exportPath = path
            updated.noteTitle = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            try saveReview(updated)
        }
        guard let url = ObsidianVault.openURL(vault: vault, relativePath: path) else { throw ReviewError.noteNotFound }
        return (url, updated)
    }

    /// links an existing note to the review by stamping watchlist_id into it
    @discardableResult
    public func relinkNote(_ r: Review, file: URL, vault explicit: URL? = nil) throws -> Review {
        let vault = try vaultURL(explicit)
        guard let path = ObsidianNote.relative(file, to: vault) else { throw ReviewError.outsideVault }
        try ObsidianNote.stampId(r.id, into: file)
        var updated = r
        updated.exportPath = path
        updated.noteTitle = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        updated.exportedAt = DateText.timestamp(Date().addingTimeInterval(1))
        try saveReview(updated)
        return updated
    }

    /// writes the review into the vault and records where it went.
    /// refuses to replace an existing note unless overwrite is true.
    @discardableResult
    public func sendReview(_ review: Review, overwrite: Bool = false, omdb: OMDbClient? = nil,
                           vault explicitVault: URL? = nil) async throws -> (url: URL, review: Review) {
        let vault = try vaultURL(explicitVault)
        var review = review

        // a note already carrying this review's id wins, even if it was renamed or moved in obsidian
        let located = review.isSent ? try locateNote(review, vault: vault) : nil
        if let located {
            review.noteTitle = (located as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        }
        let relative = located ?? ObsidianNote.relativePath(review, config: config)
        let url = vault.appendingPathComponent(relative)
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) && !overwrite {
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            let ours = located != nil
            let sentAt = DateText.parseTimestamp(review.exportedAt) ?? .distantPast
            if !ours || modified.timeIntervalSince(sentAt) > 2 {
                throw ReviewError.noteExists(path: relative, editedSince: ours)
            }
        }

        var imdbId: String?
        var ratings: ExternalRatings?
        if review.mediaType == .movie, let client {
            imdbId = try? await client.movie(review.tmdbId, ttl: CacheTTL.providers).imdbId
            if let imdbId, !imdbId.isEmpty, let omdb = omdb ?? omdbClient {
                ratings = try? await omdb.ratings(imdbId: imdbId)
            }
            if imdbId?.isEmpty == true { imdbId = nil }
        }

        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ObsidianNote.markdown(review, imdbId: imdbId, ratings: ratings).write(to: url, atomically: true, encoding: .utf8)

        // create the show index note the season links to, if index notes are enabled and it is missing
        let indexFolder = config.obsidianIndexFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if review.mediaType == .tv, !indexFolder.isEmpty,
           let link = ObsidianNote.wikiLink(review.connectedTo) {
            let name = String(link.dropFirst(2).dropLast(2)).components(separatedBy: "|")[0]
            let indexURL = vault.appendingPathComponent(indexFolder).appendingPathComponent(ObsidianNote.filename(name) + ".md")
            if !fm.fileExists(atPath: indexURL.path) {
                try fm.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ObsidianNote.indexNote(name: name).write(to: indexURL, atomically: true, encoding: .utf8)
            }
        }

        var saved = review
        saved.exportPath = relative
        saved.exportedAt = DateText.timestamp(Date().addingTimeInterval(1))
        try saveReview(saved)
        return (url, saved)
    }
}
