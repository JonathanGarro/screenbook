import Foundation

// candidates

public enum ImportStatus: String, Codable, Sendable {
    /// exact or near exact match, included by default
    case ready
    /// best guess, needs a look, excluded by default
    case check
    /// nothing usable found on tmdb
    case unmatched
    /// note already carries a watchlist_id that watchlist knows about
    case alreadyLinked
    /// another note maps to the same review id
    case duplicate
}

public struct ImportMatch: Codable, Hashable, Sendable {
    public var tmdbId: Int
    public var title: String
    public var year: Int?
    public var via: String
}

/// one note found in the vault and what it maps to
public struct ImportCandidate: Identifiable, Codable, Hashable, Sendable {
    public var relativePath: String
    public var noteName: String
    public var mediaType: MediaType
    public var season: Int
    public var searchName: String
    public var yearHint: Int?
    public var imdbId: String?
    public var existingId: String?

    public var rating: Double?
    public var finishedOn: String?
    public var connectedTo: String?
    public var seriesIndex: Int?
    public var rewatch: Bool
    public var body: String

    public var match: ImportMatch?
    public var status: ImportStatus = .unmatched
    public var include: Bool = false
    public var note: String?
    /// new note name chosen in fix; the file is renamed and links to it are updated
    public var renameTo: String?

    public var id: String { relativePath }

    /// the watchlist_id this note will carry
    public var reviewId: String? {
        if let existingId { return existingId }
        guard let match else { return nil }
        return "\(mediaType.rawValue)-\(match.tmdbId)-\(season)"
    }
}

public struct ImportSummary: Sendable {
    public var imported = 0
    public var stamped = 0
    public var showsAdded: [String] = []
    public var renamed: [String] = []
    public var linksUpdated = 0
    public var skipped = 0
    public var errors: [String] = []
    public var backup: URL?
}

// parsing

public enum NoteImport {
    /// "Silo - Season 3" becomes ("Silo", 3); anything else is the whole name as season 1
    public static func splitSeason(_ name: String) -> (show: String, season: Int) {
        let pattern = #"^(.*?)\s*(?:-\s*)?Season\s+(\d+)$"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let showRange = Range(m.range(at: 1), in: name), let numRange = Range(m.range(at: 2), in: name),
           let n = Int(name[numRange]) {
            return (String(name[showRange]), n)
        }
        return (name, 1)
    }

    /// "A Christmas Carol (2019)" becomes ("A Christmas Carol", 2019)
    public static func splitYear(_ name: String) -> (name: String, year: Int?) {
        let pattern = #"^(.*?)\s*\((\d{4})\)$"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let nameRange = Range(m.range(at: 1), in: name), let yearRange = Range(m.range(at: 2), in: name) {
            return (String(name[nameRange]), Int(name[yearRange]))
        }
        return (name, nil)
    }

    /// letters and digits only, lowercased, so "Dune - Part Two" equals "Dune: Part Two"
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: "and")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
    }

    static func stripArticle(_ s: String) -> String {
        s.hasPrefix("the") ? String(s.dropFirst(3)) : s
    }

    /// builds a candidate from a note's text
    public static func candidate(relativePath: String, text: String, mediaType: MediaType) -> ImportCandidate {
        let fileName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let (props, rawBody) = ObsidianNote.parse(text)
        var values: [String: String] = [:]
        for p in props { values[p.key] = ObsidianNote.scalar(p.value) }

        var season = 0
        var searchName = fileName
        if mediaType == .tv {
            let split = splitSeason(fileName)
            searchName = split.show
            season = split.season
        }
        let yearSplit = splitYear(searchName)
        searchName = yearSplit.name

        var connected = values["connected_to"].flatMap { $0.isEmpty ? nil : $0 }
        if let c = connected, c.hasPrefix("[[") && c.hasSuffix("]]") {
            connected = String(c.dropFirst(2).dropLast(2)).components(separatedBy: "|")[0]
        }

        // drop the leading "# heading" line and surrounding blank lines
        var bodyLines = rawBody.components(separatedBy: "\n")
        while let first = bodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeFirst() }
        if let first = bodyLines.first, first.hasPrefix("# ") { bodyLines.removeFirst() }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let imdb = values["imdb_id"].flatMap { $0.hasPrefix("tt") ? $0 : nil }
        return ImportCandidate(
            relativePath: relativePath, noteName: fileName, mediaType: mediaType, season: season,
            searchName: searchName, yearHint: yearSplit.year, imdbId: imdb,
            existingId: values[ObsidianNote.idKey].flatMap { $0.isEmpty ? nil : $0 },
            rating: values["rating"].flatMap(Double.init), finishedOn: DateText.normalize(values["finished_on"]),
            connectedTo: connected, seriesIndex: values["film_series_index"].flatMap { Int($0) },
            rewatch: values["rewatch"]?.lowercased() == "true", body: body
        )
    }

    /// parses "tv-123-2" into its parts
    public static func parseId(_ id: String) -> (MediaType, Int, Int)? {
        let parts = id.split(separator: "-")
        guard parts.count == 3, let type = MediaType(rawValue: String(parts[0])),
              let tmdb = Int(parts[1]), let season = Int(parts[2]) else { return nil }
        return (type, tmdb, season)
    }
}

// renaming

public enum NoteRename {
    static func pattern(for name: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // ![[folder/Name#heading|alias]] with the folder, heading, and alias parts optional
        return try? NSRegularExpression(pattern: #"(!?\[\[)([^\]\|#\^]*/)?"# + escaped + #"((?:[#\^][^\]\|]*)?(?:\|[^\]]*)?\]\])"#,
                                        options: [.caseInsensitive])
    }

    /// rewrites wikilinks to a renamed note, keeping folder prefixes, headings, and aliases
    public static func rewrite(_ text: String, from old: String, to new: String) -> (String, Int) {
        guard let re = pattern(for: old) else { return (text, 0) }
        let range = NSRange(text.startIndex..., in: text)
        let count = re.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let template = "$1$2" + NSRegularExpression.escapedTemplate(for: new) + "$3"
        return (re.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }

    /// every markdown file in the vault, skipping hidden folders such as .obsidian and .trash
    static func vaultNotes(_ vault: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "md" }
    }

    /// files that link to a note name, with how many links each holds
    public static func references(to name: String, in vault: URL) -> [(path: String, count: Int)] {
        guard let re = pattern(for: name) else { return [] }
        return vaultNotes(vault).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let n = re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            guard n > 0, let rel = ObsidianNote.relative(url, to: vault) else { return nil }
            return (rel, n)
        }
    }

    /// true when another note in the vault has the same name, which makes bare [[links]] ambiguous
    public static func hasNamesake(_ name: String, otherThan file: URL, in vault: URL) -> Bool {
        let target = name.lowercased()
        let me = file.standardizedFileURL.path
        return vaultNotes(vault).contains {
            $0.deletingPathExtension().lastPathComponent.lowercased() == target && $0.standardizedFileURL.path != me
        }
    }

    /// default new name for a fix: tmdb's title, keeping a "- Season N" suffix the note already had
    public static func suggestedName(for c: ImportCandidate, title: String) -> String {
        var name = ObsidianNote.filename(title)
        if c.mediaType == .tv, NoteImport.splitSeason(c.noteName).show != c.noteName {
            name += " - Season \(c.season)"
        }
        return name
    }
}

// service

extension WatchlistService {
    public func linkReferences(to name: String) throws -> [(path: String, count: Int)] {
        NoteRename.references(to: name, in: try vaultURL())
    }

    /// reads every note in the movie and tv folders. no network, no writes.
    public func scanVaultForImport(vault explicit: URL? = nil) throws -> [ImportCandidate] {
        let vault = try vaultURL(explicit)
        var out: [ImportCandidate] = []
        for (folder, type) in [(config.obsidianFilmFolder, MediaType.movie), (config.obsidianTVFolder, MediaType.tv)] {
            let root = vault.appendingPathComponent(folder)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where url.pathExtension.lowercased() == "md" {
                guard let rel = ObsidianNote.relative(url, to: vault),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append(NoteImport.candidate(relativePath: rel, text: text, mediaType: type))
            }
        }
        return out.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// finds a tmdb match for each candidate and sets its status
    public func matchImport(_ candidates: [ImportCandidate], progress: ((Int, Int) -> Void)? = nil) async throws -> [ImportCandidate] {
        guard let client else { throw TMDBError.missingAPIKey }
        let known = Set(try db.allReviews().map(\.id))
        var showCache: [String: (ImportMatch?, Bool)] = [:]
        var result: [ImportCandidate] = []

        for (i, var c) in candidates.enumerated() {
            progress?(i + 1, candidates.count)
            if let existing = c.existingId, let (type, tmdb, _) = NoteImport.parseId(existing) {
                c.match = ImportMatch(tmdbId: tmdb, title: c.searchName, year: nil, via: "watchlist_id")
                c.mediaType = type
                c.status = known.contains(existing) ? .alreadyLinked : .ready
                result.append(c)
                continue
            }
            do {
                switch c.mediaType {
                case .movie:
                    (c.match, c.status) = try await matchMovie(c, client: client)
                case .tv:
                    let key = "\(NoteImport.normalize(c.searchName))-\(c.yearHint ?? 0)"
                    if let cached = showCache[key] {
                        c.match = cached.0
                        c.status = cached.0 == nil ? .unmatched : (cached.1 ? .ready : .check)
                    } else {
                        let (m, s) = try await matchShow(c, client: client)
                        showCache[key] = (m, s == .ready)
                        c.match = m
                        c.status = s
                    }
                }
            } catch {
                c.status = .unmatched
                c.note = error.localizedDescription
            }
            result.append(c)
        }

        // a season note only fits a show that has that many seasons
        for i in result.indices where result[i].mediaType == .tv && result[i].existingId == nil
            && [.ready, .check].contains(result[i].status) {
            guard let m = result[i].match, let details = try? await client.tv(m.tmdbId) else { continue }
            let regular = (details.seasons ?? []).filter { $0.seasonNumber > 0 }.map(\.seasonNumber).max() ?? (details.numberOfSeasons ?? 0)
            if result[i].season > regular {
                result[i].status = .check
                result[i].note = "\(m.title) has \(regular) season\(regular == 1 ? "" : "s")"
            }
        }

        for i in result.indices { result[i].include = result[i].status == .ready }
        return try flagDuplicates(result)
    }

    /// two notes cannot share one review id: the first keeps it, later ones are marked duplicate and left out.
    /// run again after a fix, since picking a title by hand can create a clash.
    public func flagDuplicates(_ candidates: [ImportCandidate]) throws -> [ImportCandidate] {
        let known = Set(try db.allReviews().map(\.id))
        var result = candidates
        var owner: [String: String] = [:]
        for i in result.indices {
            guard [.ready, .check, .duplicate].contains(result[i].status), let id = result[i].reviewId else { continue }
            if result[i].status == .duplicate { result[i].status = .check; result[i].note = nil }
            if let first = owner[id] {
                result[i].status = .duplicate
                result[i].include = false
                result[i].note = "Same title as \(first)"
            } else if result[i].existingId == nil && known.contains(id) {
                result[i].status = .duplicate
                result[i].include = false
                result[i].note = "Already linked to another note"
            } else if result[i].include || result[i].status == .ready {
                owner[id] = result[i].noteName
            }
        }
        return result
    }

    /// picks a result by normalized title. exact matches released after the watch date are dropped;
    /// several exact matches from different years count as ambiguous and need a check.
    private func pick(_ results: [SearchResult], name: String, year: Int?, watchedBy: String?) -> (SearchResult, ImportStatus, String)? {
        let target = NoteImport.normalize(name)
        func names(_ r: SearchResult) -> [String] {
            [r.title, r.name, r.originalTitle, r.originalName].compactMap { $0 }.map(NoteImport.normalize)
        }
        let exact = results.filter { names($0).contains(target) }
        let loose = results.filter { r in names(r).contains { NoteImport.stripArticle($0) == NoteImport.stripArticle(target) } }
        var pool = exact.isEmpty ? loose : exact
        if let watchedBy {
            let released = pool.filter { ($0.date ?? "0000") <= watchedBy }
            if !released.isEmpty { pool = released }
        }
        if !pool.isEmpty {
            if let year {
                let byYear = pool.filter { $0.year == year }
                if let best = byYear.max(by: { ($0.popularity ?? 0) < ($1.popularity ?? 0) }) { return (best, .ready, "title and year") }
            }
            let ranked = pool.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            let best = ranked[0]
            // a same-name title counts as competition only if it is at least a quarter as popular
            let rivals = ranked.dropFirst().filter { $0.year != best.year && ($0.popularity ?? 0) >= (best.popularity ?? 0) * 0.25 }
            if best.date == nil { return (best, .check, "title, no release date") }
            return rivals.isEmpty ? (best, .ready, "title") : (best, .check, "title, \(pool.count) with this name")
        }
        return results.first.map { ($0, .check, "closest title") }
    }

    private func matchMovie(_ c: ImportCandidate, client: TMDBClient) async throws -> (ImportMatch?, ImportStatus) {
        if let imdb = c.imdbId {
            let found = try await client.find(imdbId: imdb)
            if let m = found.movies.first {
                return (ImportMatch(tmdbId: m.id, title: m.displayTitle, year: m.year, via: "imdb id"), .ready)
            }
        }
        var results = try await client.searchMovies(c.searchName, year: c.yearHint)
        if results.isEmpty, c.yearHint != nil { results = try await client.searchMovies(c.searchName) }
        guard let (r, status, via) = pick(results, name: c.searchName, year: c.yearHint, watchedBy: c.finishedOn) else { return (nil, .unmatched) }
        return (ImportMatch(tmdbId: r.id, title: r.displayTitle, year: r.year, via: via), status)
    }

    private func matchShow(_ c: ImportCandidate, client: TMDBClient) async throws -> (ImportMatch?, ImportStatus) {
        var results = try await client.searchShows(c.searchName, year: c.yearHint)
        if results.isEmpty, c.yearHint != nil { results = try await client.searchShows(c.searchName) }
        guard let (r, status, via) = pick(results, name: c.searchName, year: c.yearHint, watchedBy: c.finishedOn) else { return (nil, .unmatched) }
        return (ImportMatch(tmdbId: r.id, title: r.displayTitle, year: r.year, via: via), status)
    }

    /// points a candidate at a result the user picked by hand
    public func rematch(_ c: ImportCandidate, to r: SearchResult, renameTo: String? = nil) -> ImportCandidate {
        var c = c
        let trimmed = renameTo.map { ObsidianNote.filename($0) }
        c.renameTo = (trimmed == nil || trimmed == c.noteName) ? nil : trimmed
        if let kind = r.kind, kind != c.mediaType {
            c.mediaType = kind
            c.season = kind == .movie ? 0 : max(1, NoteImport.splitSeason(c.noteName).season)
        }
        c.match = ImportMatch(tmdbId: r.id, title: r.displayTitle, year: r.year, via: "picked")
        c.status = .ready
        c.include = true
        c.note = nil
        return c
    }

    /// zips the movie and tv folders into outputs/ before any note is touched
    public func backupVaultFolders(vault explicit: URL? = nil, extraFiles: [String] = []) throws -> URL {
        let vault = try vaultURL(explicit)
        try paths.ensureDirectories()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = paths.outputsDir.appendingPathComponent("obsidian-backup-\(f.string(from: Date())).zip")
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("watchlist-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for folder in [config.obsidianFilmFolder, config.obsidianTVFolder] where !folder.isEmpty {
            let src = vault.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let target = staging.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: target)
        }
        for rel in extraFiles {
            let src = vault.appendingPathComponent(rel)
            let target = staging.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: src.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: target)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", staging.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return dest
    }

    /// stamps ids into the included notes, records them as sent reviews, and optionally adds running shows
    public func applyImport(_ candidates: [ImportCandidate], addRunningShows: Bool, backup: Bool = true,
                            vault explicit: URL? = nil, progress: ((Int, Int) -> Void)? = nil) async throws -> ImportSummary {
        let vault = try vaultURL(explicit)
        var summary = ImportSummary()
        var chosen = candidates.filter { $0.include && $0.reviewId != nil && [.ready, .check].contains($0.status) }
        summary.skipped = candidates.count - chosen.count

        // renames: check targets first, then back up every file whose links will change
        let fm = FileManager.default
        var renames: [(index: Int, old: String, new: String, from: URL, to: URL)] = []
        for (i, c) in chosen.enumerated() {
            guard let newName = c.renameTo, newName != c.noteName else { continue }
            let from = vault.appendingPathComponent(c.relativePath)
            let to = from.deletingLastPathComponent().appendingPathComponent(newName + ".md")
            if fm.fileExists(atPath: to.path) || renames.contains(where: { $0.to == to }) {
                summary.errors.append("\(c.noteName): not renamed, a note named \(newName) already exists")
                continue
            }
            renames.append((i, c.noteName, newName, from, to))
        }
        // a name shared with another note makes bare links ambiguous, so those links stay as they are
        let ambiguous = Set(renames.filter { NoteRename.hasNamesake($0.old, otherThan: $0.from, in: vault) }.map(\.old))
        for name in ambiguous.sorted() {
            summary.errors.append("\(name): renamed, but links were left as they are because another note is also named \(name)")
        }
        let linkFiles = renames.isEmpty ? [] : Array(Set(renames.filter { !ambiguous.contains($0.old) }
            .flatMap { NoteRename.references(to: $0.old, in: vault).map(\.path) }))
        if backup, !chosen.isEmpty { summary.backup = try backupVaultFolders(vault: vault, extraFiles: linkFiles) }

        for r in renames {
            do {
                try fm.moveItem(at: r.from, to: r.to)
                // retitle the heading when it was the old name
                var text = try String(contentsOf: r.to, encoding: .utf8)
                if let range = text.range(of: "\n# \(r.old)\n") {
                    text.replaceSubrange(range, with: "\n# \(r.new)\n")
                    try text.write(to: r.to, atomically: true, encoding: .utf8)
                }
                chosen[r.index].relativePath = ObsidianNote.relative(r.to, to: vault) ?? chosen[r.index].relativePath
                chosen[r.index].noteName = r.new
                summary.renamed.append("\(r.old) to \(r.new)")
            } catch {
                summary.errors.append("\(r.old): rename failed, \(error.localizedDescription)")
            }
        }
        let done = renames.filter { summary.renamed.contains("\($0.old) to \($0.new)") && !ambiguous.contains($0.old) }
        if !done.isEmpty {
            for url in NoteRename.vaultNotes(vault) {
                guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var changed = 0
                for r in done {
                    let (out, n) = NoteRename.rewrite(text, from: r.old, to: r.new)
                    text = out
                    changed += n
                }
                if changed > 0 {
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                    summary.linksUpdated += changed
                }
            }
        }

        var lastReviewed: [Int: (season: Int, day: String?)] = [:]
        var claimed = Set(try db.allReviews().map(\.id))
        for (i, c) in chosen.enumerated() {
            progress?(i + 1, chosen.count)
            guard let id = c.reviewId, let (type, tmdb, season) = NoteImport.parseId(id) else { continue }
            // never give a second note an id that is already taken
            if c.existingId == nil && claimed.contains(id) {
                summary.errors.append("\(c.noteName): skipped, another note is already linked to the same title")
                continue
            }
            claimed.insert(id)
            do {
                if c.existingId == nil {
                    try ObsidianNote.stampId(id, into: vault.appendingPathComponent(c.relativePath))
                    summary.stamped += 1
                }
                if try db.review(tmdbId: tmdb, mediaType: type, season: season) == nil {
                    try saveReview(Review(tmdbId: tmdb, mediaType: type, season: season, noteTitle: c.noteName,
                                          rating: c.rating, finishedOn: c.finishedOn, body: c.body, rewatch: c.rewatch,
                                          connectedTo: c.connectedTo, seriesIndex: c.seriesIndex,
                                          exportedAt: DateText.timestamp(Date().addingTimeInterval(1)), exportPath: c.relativePath))
                    summary.imported += 1
                }
                if type == .tv, season >= (lastReviewed[tmdb]?.season ?? 0) {
                    lastReviewed[tmdb] = (season, c.finishedOn)
                }
            } catch {
                summary.errors.append("\(c.noteName): \(error.localizedDescription)")
            }
        }

        guard addRunningShows, client != nil else { return summary }
        for (tmdb, last) in lastReviewed {
            if try db.title(tmdbId: tmdb, mediaType: .tv) != nil { continue }
            do {
                let details = try await client!.tv(tmdb)
                let running = details.status == "Returning Series" || details.status == "In Production" || details.inProduction == true
                guard running else { continue }
                let show = try await add(SearchResult(id: tmdb, mediaType: "tv", name: details.name))
                let seasons = try db.seasons(tmdbId: tmdb)
                if let count = seasons.first(where: { $0.seasonNumber == last.season })?.episodeCount, count > 0 {
                    let eps = EpisodeMath.upTo(EpisodeRef(season: last.season, episode: count), seasons: seasons)
                    try db.setWatched(tmdbId: tmdb, eps, watched: true, on: last.day ?? today)
                }
                summary.showsAdded.append(show.title)
            } catch {
                summary.errors.append("show \(tmdb): \(error.localizedDescription)")
            }
        }
        summary.showsAdded.sort()
        return summary
    }
}
