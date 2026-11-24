import Foundation

// standard properties

extension ObsidianNote {
    /// the property order every note uses, matching the review template
    public static func standardKeys(_ type: MediaType) -> [String] {
        let shared = ["type", "rating", "stars", "finished_on", "connected_to", "film_series_index", "rewatch"]
        let movie = ["imdb_id", "imdb_link", "imdb_rating", "imdb_votes", "metascore", "rotten_tomatoes", "my_rating_delta"]
        return shared + (type == .movie ? movie : []) + [idKey]
    }

    /// adds missing standard properties (blank, or false for rewatch) and puts them in the standard order. values are untouched,
    /// other properties keep their order after the standard ones, watchlist_id is always last and never added blank.
    /// returns nil when the note is already tidy or has no frontmatter.
    public static func tidy(_ text: String, type: MediaType) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let (props, body) = parse(text)
        guard !props.isEmpty || text.hasPrefix("---\n---") else { return nil }
        var byKey: [String: Property] = [:]
        for p in props where byKey[p.key] == nil { byKey[p.key] = p }
        let standard = standardKeys(type)
        var lines: [String] = []
        for key in standard where key != idKey {
            if let p = byKey[key] {
                lines += p.lines
            } else if key == "rewatch" {
                // matches the template's unchecked box
                lines.append("rewatch: false")
            } else {
                lines.append("\(key):")
            }
        }
        // other properties keep their order, then watchlist_id always closes the block
        var seen = Set(standard)
        for p in props where !seen.contains(p.key) {
            seen.insert(p.key)
            lines += p.lines
        }
        if let id = byKey[idKey] { lines += id.lines }
        // the title goes right under the properties: blank lines there show as an empty row in obsidian
        var bodyLines = body.components(separatedBy: "\n")
        while bodyLines.count > 1, bodyLines[0].trimmingCharacters(in: .whitespaces).isEmpty { bodyLines.removeFirst() }
        let trimmed = bodyLines.joined(separator: "\n")
        let out = "---\n" + lines.joined(separator: "\n") + "\n---\n" + trimmed
        return out == text ? nil : out
    }

    /// tidies a note file in place; returns true when it changed
    @discardableResult
    public static func tidyFile(_ url: URL, type: MediaType) throws -> Bool {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let out = tidy(text, type: type) else { return false }
        try out.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}

// vault pass

public struct TidySummary: Sendable {
    public var checked = 0
    public var changed: [String] = []
    public var addedKeys: [String: Int] = [:]
    public var reordered = 0
    public var backup: URL?
    /// before and after for a few changed notes, for previews
    public var samples: [(path: String, before: String, after: String)] = []
}

extension WatchlistService {
    /// brings every note in the movie and tv folders to the standard property set and order
    public func tidyVault(dryRun: Bool = true, vault explicit: URL? = nil) throws -> TidySummary {
        let vault = try vaultURL(explicit)
        var summary = TidySummary()
        var pending: [(URL, String, String, String)] = []
        for (folder, folderType) in [(config.obsidianFilmFolder, MediaType.movie), (config.obsidianTVFolder, MediaType.tv)] where !folder.isEmpty {
            for url in NoteRename.vaultNotes(vault.appendingPathComponent(folder)) {
                summary.checked += 1
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // a linked note's type comes from its watchlist_id (a movie filed under tv stays a movie)
                let type = ObsidianNote.noteId(in: text).flatMap(NoteImport.parseId).map { $0.0 } ?? folderType
                guard let out = ObsidianNote.tidy(text, type: type),
                      let rel = ObsidianNote.relative(url, to: vault) else { continue }
                let before = ObsidianNote.parse(text).properties.map(\.key)
                let after = ObsidianNote.parse(out).properties.map(\.key)
                for k in after where !before.contains(k) { summary.addedKeys[k, default: 0] += 1 }
                if before != after.filter({ before.contains($0) }) { summary.reordered += 1 }
                pending.append((url, rel, text, out))
            }
        }
        summary.changed = pending.map(\.1).sorted()
        // previews: one movie and one tv note when available
        for folder in [config.obsidianFilmFolder, config.obsidianTVFolder] {
            if let p = pending.first(where: { $0.1.hasPrefix(folder + "/") }) {
                summary.samples.append((p.1, p.2, p.3))
            }
        }
        if !dryRun, !pending.isEmpty {
            summary.backup = try backupVaultFolders(vault: vault)
            for p in pending { try p.3.write(to: p.0, atomically: true, encoding: .utf8) }
        }
        return summary
    }
}
