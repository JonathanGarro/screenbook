import Foundation
import WatchlistCore

// usage

let usage = """
usage: screenbook [--data-dir PATH] <command> [options]

commands:
  add <search term> [--caught-up] [--pick N]   search tmdb, pick a match, save it
  remove <tmdb_id> [--movie | --tv]            remove a saved title
  list                                         show the watchlist
  check [--force]                              refresh all titles and print what is new
  watch <tmdb_id> <season> <episode> [--unwatch]
  watch <tmdb_id> --all-up-to <season> <episode>
  stop <tmdb_id> [--movie | --tv]              stop watching or tracking, keeping progress
  resume <tmdb_id> [--movie | --tv]            resume a stopped title
  available <tmdb_id> on|off                   treat every listed episode as released (streaming drops)
  import-reviews [--apply] [--include-check] [--add-shows on|off]
                                               link existing obsidian review notes (dry run unless --apply)
  fill-ratings [--apply] [--refresh]           fill imdb, metascore, rotten tomatoes in linked movie notes (dry run unless --apply)
  sync-reviews                                 pull obsidian edits into watchlist's reviews
  tidy [--apply]                               give every note the standard properties in the standard order (dry run unless --apply)
  link "<note name>" <imdb link or id>         link an unlinked note to a title by its imdb id
  audit-series [--apply] [--keys-only] [--skip "Note A,Note B"]
                                               add film_series_index to notes and fill it from tmdb collections
  digest [--force]                             write outputs/digest.md and print it
  export                                       write outputs/watchlist.csv
  config [--region XX] [--streaming on|off] [--rent-buy on|off]
         [--check-on-open on|off] [--menu-bar on|off]
         [--notify on|off] [--notify-movies on|off] [--periodic on|off] [--api-key KEY]
  paths                                        show where data is stored
"""

// helpers

struct CLIError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func takeFlag(_ args: inout [String], _ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func takeOption(_ args: inout [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func int(_ text: String, _ what: String) -> Int {
    guard let v = Int(text) else { fail("\(what) must be a number, got '\(text)'") }
    return v
}

func onOff(_ text: String) -> Bool {
    switch text.lowercased() {
    case "on", "true", "yes", "1": return true
    case "off", "false", "no", "0": return false
    default: fail("expected on or off, got '\(text)'")
    }
}

func mediaFilter(_ args: inout [String]) -> MediaType? {
    let movie = takeFlag(&args, "--movie")
    let tv = takeFlag(&args, "--tv")
    if movie && tv { fail("use only one of --movie or --tv") }
    return movie ? .movie : (tv ? .tv : nil)
}

func listTable(_ service: WatchlistService) throws -> String {
    let today = service.today
    let rows = try service.titles().map { t -> [String] in
        var next = ""
        var note = ""
        if let stopped = t.stoppedOn {
            return [String(t.tmdbId), t.mediaType.label, t.title, t.year.map(String.init) ?? "", "", "stopped \(stopped)"]
        }
        switch t.mediaType {
        case .movie:
            if let d = t.regionReleaseDate, d > today {
                next = d
                note = "release"
            } else if let d = t.digitalReleaseDate, d > today {
                next = d
                note = "digital, released \(t.regionReleaseDate ?? "")"
            } else if let d = t.regionReleaseDate {
                note = "released \(d)"
            } else {
                note = "no date yet"
            }
        case .tv:
            if t.allAvailable {
                note = "all episodes out"
            } else if let d = t.nextAirDate {
                next = d
                note = t.nextAir?.code ?? ""
            } else {
                note = t.status ?? ""
            }
            let unwatched = (try? service.unwatchedAired(t).count) ?? 0
            if unwatched > 0 { note += note.isEmpty ? "\(unwatched) unwatched" : ", \(unwatched) unwatched" }
        }
        return [String(t.tmdbId), t.mediaType.label, t.title, t.year.map(String.init) ?? "", next, note]
    }
    if rows.isEmpty { return "Your watchlist is empty. Add something with: screenbook add <search term>" }
    let sorted = rows.sorted { a, b in
        switch (a[4].isEmpty, b[4].isEmpty) {
        case (false, true): return true
        case (true, false): return false
        default: return a[4] == b[4] ? a[2].lowercased() < b[2].lowercased() : a[4] < b[4]
        }
    }
    return TextTable.render(header: ["ID", "Type", "Title", "Year", "Next", "Notes"], rows: sorted)
}

// main

var args = Array(CommandLine.arguments.dropFirst())
let dataDir = takeOption(&args, "--data-dir")
if args.isEmpty || args.first == "-h" || args.first == "--help" || args.first == "help" {
    print(usage)
    exit(0)
}
let command = args.removeFirst()
let paths = AppPaths.standard(override: dataDir)

do {
    let service = try WatchlistService.standard(paths: paths)

    switch command {
    case "add":
        let caughtUp = takeFlag(&args, "--caught-up")
        let pick = takeOption(&args, "--pick").map { int($0, "--pick") }
        let term = args.joined(separator: " ")
        if term.isEmpty { fail("usage: screenbook add <search term>") }
        let results = Array(try await service.search(term).prefix(10))
        if results.isEmpty { fail("No movies or shows found for '\(term)'.") }
        var choice = pick
        if choice == nil {
            for (i, r) in results.enumerated() {
                let year = r.year.map(String.init) ?? "----"
                print(String(format: "%2d. ", i + 1) + "[\(r.kind?.label ?? "?")] \(r.displayTitle) (\(year))  id \(r.id)")
            }
            print("Pick a number (or press return to cancel): ", terminator: "")
            guard let line = readLine(), let n = Int(line.trimmingCharacters(in: .whitespaces)) else {
                print("Cancelled.")
                exit(0)
            }
            choice = n
        }
        guard let n = choice, n >= 1, n <= results.count else { fail("Pick must be between 1 and \(results.count).") }
        let t = try await service.add(results[n - 1], caughtUp: caughtUp)
        var line = "Added \(t.title) (\(t.year.map(String.init) ?? "?")) [\(t.mediaType.label)] id \(t.tmdbId)."
        if t.mediaType == .movie, let d = t.regionReleaseDate {
            line += " \(service.config.region) release date \(d)."
        }
        if t.mediaType == .tv {
            let n = try service.unwatchedAired(t).count
            line += caughtUp ? " Marked all aired episodes watched." : " \(n) aired episodes unwatched."
        }
        print(line)

    case "remove":
        let type = mediaFilter(&args)
        guard let first = args.first else { fail("usage: screenbook remove <tmdb_id>") }
        let t = try service.remove(int(first, "tmdb_id"), type)
        print("Removed \(t.title) [\(t.mediaType.label)].")

    case "list":
        print(try listTable(service))

    case "check":
        let force = takeFlag(&args, "--force")
        let report = try await service.check(force: force)
        print(Digest.summary(report))

    case "watch":
        let unwatch = takeFlag(&args, "--unwatch")
        if let i = args.firstIndex(of: "--all-up-to") {
            args.remove(at: i)
            guard args.count == 3 else { fail("usage: screenbook watch <tmdb_id> --all-up-to <season> <episode>") }
            let id = int(args[0], "tmdb_id")
            let count = try await service.markAllUpTo(id, season: int(args[1], "season"), episode: int(args[2], "episode"))
            let t = try service.resolve(id, .tv)
            print("Marked \(count) episodes of \(t.title) watched, up to \(EpisodeRef(season: int(args[1], "season"), episode: int(args[2], "episode")).code).")
        } else {
            guard args.count == 3 else { fail("usage: screenbook watch <tmdb_id> <season> <episode>") }
            let id = int(args[0], "tmdb_id")
            let ref = EpisodeRef(season: int(args[1], "season"), episode: int(args[2], "episode"))
            try service.setWatched(id, season: ref.season, episode: ref.episode, watched: !unwatch)
            let t = try service.resolve(id, .tv)
            print("\(unwatch ? "Unmarked" : "Marked") \(t.title) \(ref.code) \(unwatch ? "as unwatched" : "watched").")
        }

    case "stop", "resume":
        let type = mediaFilter(&args)
        guard let first = args.first else { fail("usage: screenbook \(command) <tmdb_id>") }
        let t = try await service.setStopped(int(first, "tmdb_id"), type, stopped: command == "stop")
        print(command == "stop" ? "Stopped \(t.title). Progress is kept; resume any time." : "Resumed \(t.title).")

    case "available":
        guard args.count == 2 else { fail("usage: screenbook available <tmdb_id> on|off") }
        let t = try service.resolve(int(args[0], "tmdb_id"), .tv)
        try service.setAllAvailable(t, onOff(args[1]))
        let updated = try service.resolve(t.tmdbId, .tv)
        print("\(t.title): all episodes out is \(updated.allAvailable ? "on" : "off"), \(try service.unwatchedAired(updated).count) unwatched.")

    case "import-reviews":
        let apply = takeFlag(&args, "--apply")
        let includeCheck = takeFlag(&args, "--include-check")
        let addShows = takeOption(&args, "--add-shows").map(onOff) ?? true
        let scanned = try service.scanVaultForImport()
        print("Found \(scanned.count) notes. Matching on TMDB...")
        var matched = try await service.matchImport(scanned) { done, total in
            if done % 50 == 0 || done == total { print("  \(done)/\(total)") }
        }
        if includeCheck {
            for i in matched.indices where matched[i].status == .check { matched[i].include = true }
        }
        func group(_ s: ImportStatus) -> [ImportCandidate] { matched.filter { $0.status == s } }
        func label(_ c: ImportCandidate) -> String {
            let m = c.match.map { "\($0.title)\($0.year.map { " (\($0))" } ?? "") [\($0.via)]" } ?? "no match"
            let season = c.mediaType == .tv ? " S\(c.season)" : ""
            return "  \(c.noteName) -> \(m)\(season)\(c.note.map { "  (\($0))" } ?? "")"
        }
        print("")
        print("ready: \(group(.ready).count)  check: \(group(.check).count)  unmatched: \(group(.unmatched).count)  already linked: \(group(.alreadyLinked).count)  duplicate: \(group(.duplicate).count)")
        for (name, s) in [("Check (closest guess)", ImportStatus.check), ("Unmatched", .unmatched), ("Duplicate", .duplicate)] where !group(s).isEmpty {
            print("")
            print("\(name):")
            group(s).forEach { print(label($0)) }
        }
        if takeFlag(&args, "--list-title-matches") || ProcessInfo.processInfo.environment["WATCHLIST_LIST_MATCHES"] != nil {
            print("")
            print("Ready by title (not imdb id):")
            matched.filter { $0.status == .ready && ($0.match?.via ?? "").hasPrefix("title") }.forEach { print(label($0)) }
        }
        if apply {
            let summary = try await service.applyImport(matched, addRunningShows: addShows) { done, total in
                if done % 100 == 0 || done == total { print("  applied \(done)/\(total)") }
            }
            print("")
            print("Imported \(summary.imported) reviews, stamped \(summary.stamped) notes, skipped \(summary.skipped).")
            if let b = summary.backup { print("Backup: \(b.path)") }
            if !summary.showsAdded.isEmpty { print("Added running shows: \(summary.showsAdded.joined(separator: ", "))") }
            summary.errors.forEach { print("Error: \($0)") }
        } else {
            print("")
            print("Dry run. Nothing was written. Run with --apply to import (add --include-check to include closest guesses).")
        }

    case "fill-ratings":
        let apply = takeFlag(&args, "--apply")
        let refresh = takeFlag(&args, "--refresh")
        let s = try await service.fillRatings(refresh: refresh, dryRun: !apply) { done, total in
            if done % 50 == 0 || done == total { print("  \(done)/\(total)") }
        }
        print("")
        print("\(apply ? "Updated" : "Would update") \(s.updated.count) notes. Already complete: \(s.alreadyComplete). Checked \(s.checked).")
        if !s.updated.isEmpty { print("  " + s.updated.sorted().joined(separator: "\n  ")) }
        if !s.noImdbId.isEmpty { print("No IMDb id on TMDB: " + s.noImdbId.sorted().joined(separator: ", ")) }
        if !s.notOnOMDb.isEmpty { print("Not found on OMDb: " + s.notOnOMDb.sorted().joined(separator: ", ")) }
        if !s.noteMissing.isEmpty { print("Note not found: " + s.noteMissing.sorted().joined(separator: ", ")) }
        s.errors.forEach { print("Error: \($0)") }
        if !apply { print("\nDry run. Nothing was written. Run with --apply to write.") }

    case "audit-series":
        let apply = takeFlag(&args, "--apply")
        let keysOnly = takeFlag(&args, "--keys-only")
        let skip = Set((takeOption(&args, "--skip") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let audit = try await service.auditSeries(dryRun: !apply, keysOnly: keysOnly) { done, total in
            if done % 100 == 0 || done == total { print("  \(done)/\(total)") }
        }
        print("")
        print("\(apply ? "Added" : "Would add") a blank film_series_index to \(audit.keysAdded.count) notes: \(audit.keysAdded.sorted().joined(separator: ", "))")
        print("")
        print("Blank index, in a TMDB collection (\(audit.toFill.count)):")
        for f in audit.toFill { print("  \(f.noteTitle): \(f.suggested) of \(f.of) in \(f.collection)") }
        if !audit.differs.isEmpty {
            print("")
            print("Filled, but TMDB order differs (left as is, \(audit.differs.count)):")
            for f in audit.differs { print("  \(f.noteTitle): note has \(f.current!), TMDB release order \(f.suggested) of \(f.of) in \(f.collection)") }
        }
        print("")
        print("Already matching: \(audit.matching). Not in a collection: \(audit.notInCollection).")
        audit.errors.forEach { print("Error: \($0)") }
        if apply && !keysOnly {
            let filled = try service.applySeries(audit.toFill.filter { !skip.contains($0.noteTitle) })
            print("Filled \(filled.count) indexes\(skip.isEmpty ? "" : ", skipped \(skip.count)").")
        } else {
            print("Dry run. Nothing was written. Run with --apply to add the keys and fill the blanks.")
        }

    case "link":
        guard args.count == 2 else { fail("usage: screenbook link \"<note name>\" <imdb link or id>") }
        let notes = try service.unlinkedNotes().filter { $0.noteName.caseInsensitiveCompare(args[0]) == .orderedSame }
        guard let note = notes.first else { fail("No unlinked note named \"\(args[0])\".") }
        guard NoteImport.imdbId(in: args[1]) != nil else { fail("Give an IMDb link or id like tt1234567.") }
        let found = try await service.searchForLink(args[1])
        guard let title = found.first else { fail("TMDB has nothing for that IMDb id.") }
        let id = try await service.linkNote(note, to: title)
        print("Linked \(note.noteName) to \(title.displayTitle) (\(title.year.map(String.init) ?? "?")) as \(id).")

    case "tidy":
        let apply = takeFlag(&args, "--apply")
        let s = try service.tidyVault(dryRun: !apply)
        print("\(apply ? "Tidied" : "Would tidy") \(s.changed.count) of \(s.checked) notes. Reordered: \(s.reordered).")
        if !s.addedKeys.isEmpty {
            print("Blank properties added: " + s.addedKeys.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if !apply {
            for sample in s.samples {
                func front(_ t: String) -> String { ObsidianNote.parse(t).properties.flatMap(\.lines).joined(separator: "\n") }
                print("")
                print("== \(sample.path)")
                print("-- before")
                print(front(sample.before))
                print("-- after")
                print(front(sample.after))
            }
            print("")
            print("Dry run. Nothing was written. Run with --apply (backs up the folders first).")
        } else if let b = s.backup {
            print("Backup: \(b.path)")
        }

    case "sync-reviews":
        let s = try service.syncReviewsFromObsidian()
        print("Checked \(s.checked) reviews. Pulled \(s.pulled.count) from Obsidian.")
        if !s.pulled.isEmpty { print("  " + s.pulled.sorted().joined(separator: "\n  ")) }
        if !s.conflicts.isEmpty { print("Changed in both places (open in the app to choose): " + s.conflicts.sorted().joined(separator: ", ")) }
        if !s.missing.isEmpty { print("Note missing: " + s.missing.sorted().joined(separator: ", ")) }
        s.errors.forEach { print("Error: \($0)") }

    case "digest":
        let force = takeFlag(&args, "--force")
        // reuse today's check so running check then digest does not lose the "new" items
        var report: CheckReport
        if !force, let last = service.lastReport, DateText.day(last.checkedAt) == service.today {
            report = last
        } else {
            report = try await service.check(force: force)
        }
        let (url, text) = try service.writeDigest(report)
        print(text)
        print("Wrote \(url.path)")

    case "export":
        print("Wrote \(try service.exportCSV().path)")

    case "config":
        var config = service.config
        var changed = false
        if let region = takeOption(&args, "--region") {
            guard region.count == 2 else { fail("region must be a 2 letter country code like US or GB") }
            config.region = region.uppercased()
            changed = true
        }
        if let s = takeOption(&args, "--streaming") { config.streamingEnabled = onOff(s); changed = true }
        if let s = takeOption(&args, "--rent-buy") { config.includeRentBuy = onOff(s); changed = true }
        if let s = takeOption(&args, "--check-on-open") { config.checkOnLaunch = onOff(s); changed = true }
        if let s = takeOption(&args, "--menu-bar") { config.showInMenuBar = onOff(s); changed = true }
        if let s = takeOption(&args, "--notify") { config.notifyNewEpisodes = onOff(s); changed = true }
        if let s = takeOption(&args, "--notify-movies") { config.notifyMovieReleases = onOff(s); changed = true }
        if let s = takeOption(&args, "--periodic") { config.periodicCheck = onOff(s); changed = true }
        if let key = takeOption(&args, "--api-key") {
            try APIKeyStore.save(key, paths)
            print("Saved API key to \(paths.envURL.path)")
        }
        if changed { try ConfigStore.save(config, paths) }
        print("region: \(config.region)")
        print("streaming: \(config.streamingEnabled ? "on" : "off")")
        print("rent/buy: \(config.includeRentBuy ? "on" : "off")")
        print("check on open: \(config.checkOnLaunch ? "on" : "off")")
        print("menu bar: \(config.showInMenuBar ? "on" : "off")")
        print("episode notifications: \(config.notifyNewEpisodes ? "on" : "off")")
        print("movie notifications: \(config.notifyMovieReleases ? "on" : "off")")
        print("check every 6 hours in app: \(config.periodicCheck ? "on" : "off")")
        print("api key: \(APIKeyStore.resolve(paths) == nil ? "not set" : "set")")

    case "paths":
        print("data folder: \(paths.dataDir.path)")
        print("database:    \(paths.databaseURL.path)")
        print("outputs:     \(paths.outputsDir.path)")
        print("key file:    \(paths.envURL.path)")

    default:
        print(usage)
        exit(2)
    }
} catch {
    fail("Error: \(error.localizedDescription)")
}
