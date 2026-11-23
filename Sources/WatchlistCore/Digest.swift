import Foundation

// attribution

public enum Attribution {
    public static let tmdb = "Data from TMDB (themoviedb.org). This product uses the TMDB API but is not endorsed or certified by TMDB."
    public static let justWatch = "Streaming availability provided by JustWatch via TMDB."
}

// tables

public enum TextTable {
    /// fixed width text table for terminal output
    public static func render(header: [String], rows: [[String]]) -> String {
        var widths = header.map(\.count)
        for r in rows {
            for (i, cell) in r.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        var out = [line(header), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")]
        out += rows.map(line)
        return out.joined(separator: "\n")
    }

    public static func markdown(header: [String], rows: [[String]]) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        var out = ["| " + header.map(esc).joined(separator: " | ") + " |",
                   "|" + header.map { _ in " --- " }.joined(separator: "|") + "|"]
        out += rows.map { "| " + $0.map(esc).joined(separator: " | ") + " |" }
        return out.joined(separator: "\n")
    }

    public static func csv(header: [String], rows: [[String]]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        return ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}

// digest

public enum Digest {
    public static func markdown(_ r: CheckReport, config: AppConfig) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out: [String] = []
        out.append("# Screenbook digest")
        out.append("")
        var meta = "Checked \(f.string(from: r.checkedAt)), region \(r.region)."
        if let prev = r.previousCheck { meta += " Previous check \(f.string(from: prev))." }
        out.append(meta)
        out.append("")

        func streaming(_ t: Title) -> String {
            guard config.streamingEnabled else { return "" }
            let names = r.providers[t.id]?.names(includeRentBuy: config.includeRentBuy) ?? []
            return names.isEmpty ? "-" : names.joined(separator: ", ")
        }

        out.append("## Movies released since last check")
        out.append("")
        if r.releasedMovies.isEmpty {
            out.append("None.")
        } else {
            var header = ["Title", "Year", "Release date"]
            if config.streamingEnabled { header.append("Streaming") }
            out.append(TextTable.markdown(header: header, rows: r.releasedMovies.map { t in
                var row = [t.title, t.year.map(String.init) ?? "", t.regionReleaseDate ?? ""]
                if config.streamingEnabled { row.append(streaming(t)) }
                return row
            }))
        }
        out.append("")

        out.append("## Shows with unwatched episodes")
        out.append("")
        if r.showsWithUnwatched.isEmpty {
            out.append("None. You are caught up.")
        } else {
            var header = ["Show", "New since last check", "Unwatched", "Next to watch", "Latest aired"]
            if config.streamingEnabled { header.append("Streaming") }
            out.append(TextTable.markdown(header: header, rows: r.showsWithUnwatched.map { u in
                let newText = u.newlyAired.isEmpty ? "" : u.newlyAired.map(\.code).joined(separator: ", ")
                let latest = [u.title.lastAired?.code, u.title.lastAiredDate].compactMap { $0 }.joined(separator: " on ")
                var row = [u.title.title, newText, String(u.unwatchedCount), u.firstUnwatched?.code ?? "", latest]
                if config.streamingEnabled { row.append(streaming(u.title)) }
                return row
            }))
        }
        out.append("")

        out.append("## Coming up")
        out.append("")
        let upcoming: [[String]] =
            r.upcomingMovies.map { [$0.title, "Movie", $0.regionReleaseDate ?? ""] } +
            r.upcomingEpisodes.map { [$0.title, $0.nextAir?.code ?? "TV", $0.nextAirDate ?? ""] }
        if upcoming.isEmpty {
            out.append("Nothing in the next few weeks.")
        } else {
            out.append(TextTable.markdown(header: ["Title", "What", "Date"],
                                          rows: upcoming.sorted { $0[2] < $1[2] }))
        }
        out.append("")

        if !r.errors.isEmpty {
            out.append("## Errors")
            out.append("")
            out += r.errors.map { "- \($0)" }
            out.append("")
        }

        out.append("---")
        out.append("")
        out.append(Attribution.tmdb)
        if config.streamingEnabled {
            out.append("")
            out.append(Attribution.justWatch)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// shorter plain text form printed by the check command
    public static func summary(_ r: CheckReport) -> String {
        var out: [String] = []
        if r.releasedMovies.isEmpty {
            out.append("No movies released since last check.")
        } else {
            out.append("Released since last check:")
            out += r.releasedMovies.map { "  \($0.title) (\($0.year.map(String.init) ?? "?")), released \($0.regionReleaseDate ?? "")" }
        }
        out.append("")
        let fresh = r.newEpisodeShows
        if fresh.isEmpty {
            out.append("No new episodes since last check.")
        } else {
            out.append("New episodes since last check:")
            out += fresh.map { u in
                "  \(u.title.title): \(u.newlyAired.map(\.code).joined(separator: ", ")) (\(u.unwatchedCount) unwatched)"
            }
        }
        let backlog = r.showsWithUnwatched.filter { $0.newlyAired.isEmpty }
        if !backlog.isEmpty {
            out.append("")
            out.append("Still unwatched:")
            out += backlog.map { "  \($0.title.title): \($0.unwatchedCount) unwatched, next \($0.firstUnwatched?.code ?? "")" }
        }
        if !r.errors.isEmpty {
            out.append("")
            out.append("Errors:")
            out += r.errors.map { "  \($0)" }
        }
        return out.joined(separator: "\n")
    }
}
