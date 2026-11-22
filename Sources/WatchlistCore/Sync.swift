import Foundation

// sync from obsidian

/// how a sent review compares with its note
public enum ReviewSyncState: String, Codable, Sendable {
    /// note and watchlist agree, or only the note changed and was pulled in
    case inSync
    /// the note was edited in obsidian and watchlist has unsent edits too
    case conflict
    /// no note carries this review's id
    case missing
}

public struct SyncSummary: Sendable {
    public var checked = 0
    public var pulled: [String] = []
    public var conflicts: [String] = []
    public var missing: [String] = []
    public var states: [String: ReviewSyncState] = [:]
    public var errors: [String] = []
}

extension WatchlistService {
    /// seconds of slack when comparing file times with recorded timestamps
    static let syncSlack: TimeInterval = 2

    /// maps every watchlist_id in the vault to its note, reading only the top of each file
    public func noteIndex(vault explicit: URL? = nil) throws -> [String: String] {
        let vault = try vaultURL(explicit)
        var index: [String: String] = [:]
        for url in NoteRename.vaultNotes(vault) {
            guard let head = ObsidianNote.head(url), let id = ObsidianNote.noteId(in: head),
                  index[id] == nil, let rel = ObsidianNote.relative(url, to: vault) else { continue }
            index[id] = rel
        }
        return index
    }

    /// the review as the note currently has it, keeping watchlist's ids and timestamps
    func reviewFromNote(_ r: Review, text: String, relativePath: String) -> Review {
        let c = NoteImport.candidate(relativePath: relativePath, text: text, mediaType: r.mediaType)
        var out = r
        out.noteTitle = c.noteName
        out.rating = c.rating
        out.finishedOn = c.finishedOn
        out.rewatch = c.rewatch
        out.connectedTo = c.connectedTo
        out.seriesIndex = c.seriesIndex
        out.body = c.body
        out.exportPath = relativePath
        return out
    }

    static func sameContent(_ a: Review, _ b: Review) -> Bool {
        a.noteTitle == b.noteTitle && a.rating == b.rating && a.finishedOn == b.finishedOn && a.rewatch == b.rewatch
            && (a.connectedTo ?? "") == (b.connectedTo ?? "") && a.seriesIndex == b.seriesIndex
            && a.body.trimmingCharacters(in: .whitespacesAndNewlines) == b.body.trimmingCharacters(in: .whitespacesAndNewlines)
            && a.exportPath == b.exportPath
    }

    /// records the review with send and update times equal, so it counts as matching the note
    func storeSynced(_ r: Review, at date: Date) throws {
        var r = r
        r.localEdits = false
        let stamp = DateText.timestamp(date)
        r.exportedAt = stamp
        r.updatedAt = stamp
        try db.upsertReview(r)
    }

    /// compares one sent review with its note. pulls the note in when only obsidian changed.
    /// with force, the note wins even over unsent watchlist edits.
    public func syncReview(_ r: Review, force: Bool = false, index: [String: String]? = nil,
                           vault explicit: URL? = nil) throws -> (review: Review, state: ReviewSyncState, pulled: Bool) {
        guard r.isSent else { return (r, .inSync, false) }
        let vault = try vaultURL(explicit)

        var path: String?
        if let index { path = index[r.id] } else { path = try locateNote(r, vault: vault) }
        if path == nil, let p = r.exportPath, FileManager.default.fileExists(atPath: vault.appendingPathComponent(p).path),
           let head = ObsidianNote.head(vault.appendingPathComponent(p)), ObsidianNote.noteId(in: head) == nil {
            path = p
        }
        guard let path else { return (r, .missing, false) }

        let url = vault.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (r, .missing, false) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        let sentAt = DateText.parseTimestamp(r.exportedAt) ?? .distantPast
        let noteChanged = modified.timeIntervalSince(sentAt) > Self.syncSlack
        let localChanged = r.localEdits

        let fromNote = reviewFromNote(r, text: text, relativePath: path)
        if Self.sameContent(fromNote, r) {
            // same content; refresh the baseline so later edits compare against now
            if noteChanged || localChanged { try storeSynced(r, at: max(modified, Date())) }
            var clean = r
            clean.localEdits = false
            return (clean, .inSync, false)
        }
        if !noteChanged && !force {
            // only the path or title moved, or watchlist has unsent edits; adopt a moved path quietly
            if r.exportPath != path {
                var moved = r
                moved.exportPath = path
                moved.noteTitle = fromNote.noteTitle
                try db.upsertReview(moved)
                return (moved, .inSync, false)
            }
            return (r, .inSync, false)
        }
        if localChanged && !force {
            return (r, .conflict, false)
        }
        try storeSynced(fromNote, at: max(modified, Date()))
        return (fromNote, .inSync, true)
    }

    /// syncs every sent review with its note
    public func syncReviewsFromObsidian(vault explicit: URL? = nil) throws -> SyncSummary {
        let vault = try vaultURL(explicit)
        let index = try noteIndex(vault: vault)
        var summary = SyncSummary()
        for r in try db.allReviews() where r.isSent {
            summary.checked += 1
            do {
                let result = try syncReview(r, index: index, vault: vault)
                summary.states[r.id] = result.state
                switch result.state {
                case .missing: summary.missing.append(r.noteTitle)
                case .conflict: summary.conflicts.append(r.noteTitle)
                case .inSync: if result.pulled { summary.pulled.append(result.review.noteTitle) }
                }
            } catch {
                summary.errors.append("\(r.noteTitle): \(error.localizedDescription)")
            }
        }
        return summary
    }
}
