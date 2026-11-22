import SwiftUI
import WatchlistCore

// import from obsidian

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Phase { case intro, scanning, review, applying, done }

    @State private var phase: Phase = .intro
    @State private var candidates: [ImportCandidate] = []
    @State private var progress = ""
    @State private var addShows = true
    @State private var filter: ImportStatus? = nil
    @State private var summary: ImportSummary?
    @State private var error: String?
    @State private var fixing: ImportCandidate?

    private var chosen: Int { candidates.filter { $0.include && [.ready, .check].contains($0.status) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Reviews from Obsidian").font(.title2.bold())
            switch phase {
            case .intro: intro
            case .scanning, .applying: working
            case .review: review
            case .done: done
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(width: 760, height: 640)
        .sheet(item: $fixing) { c in
            FixMatchSheet(candidate: c) { picked, renameTo in
                if let picked, let service = model.service, let i = candidates.firstIndex(where: { $0.id == c.id }) {
                    candidates[i] = service.rematch(candidates[i], to: picked, renameTo: renameTo)
                    candidates = (try? service.flagDuplicates(candidates)) ?? candidates
                }
                fixing = nil
            }
        }
    }

    // phases

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watchlist reads every note in your movie and TV folders, matches each one to TMDB, and shows you the matches before changing anything.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Movie folder: \(model.config.obsidianFilmFolder)", systemImage: "film")
                Label("TV folder: \(model.config.obsidianTVFolder)", systemImage: "tv")
            }
            .foregroundStyle(.secondary)
            Text("On import, each note gets a watchlist_id property and nothing else in it changes. A zip backup of both folders is saved first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Scan Vault") { Task { await scan() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasKey)
            }
        }
    }

    private var working: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(progress).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                filterButton(nil, "All", candidates.count)
                filterButton(.ready, "Matched", count(.ready))
                filterButton(.check, "Check", count(.check))
                filterButton(.unmatched, "No match", count(.unmatched))
                if count(.alreadyLinked) > 0 { filterButton(.alreadyLinked, "Linked", count(.alreadyLinked)) }
                if count(.duplicate) > 0 { filterButton(.duplicate, "Duplicate", count(.duplicate)) }
            }
            Text("Matched notes are included. Check means a best guess: tick it if it is right, or click Fix to pick the right title. Notes left unticked are skipped and can be imported later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(visible) { c in
                    ImportRow(candidate: c, include: binding(for: c)) { fixing = c }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            Toggle("Add shows that are still running to my watchlist, watched through the last season reviewed", isOn: $addShows)
            HStack {
                Text("\(chosen) notes will be imported").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen)") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == 0)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = summary {
                Label("Imported \(s.imported) reviews", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Text("Added watchlist_id to \(s.stamped) notes. Skipped \(s.skipped).")
                if !s.renamed.isEmpty {
                    Text("Renamed \(s.renamed.count) note\(s.renamed.count == 1 ? "" : "s") and updated \(s.linksUpdated) link\(s.linksUpdated == 1 ? "" : "s"): \(s.renamed.joined(separator: "; "))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !s.showsAdded.isEmpty {
                    Text("Added to your watchlist: \(s.showsAdded.joined(separator: ", "))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let b = s.backup {
                    HStack {
                        Text("Backup: \(b.lastPathComponent)").foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b]) }.buttonStyle(.link)
                    }
                }
                if !s.errors.isEmpty {
                    Text("Problems:").font(.headline)
                    ScrollView {
                        Text(s.errors.joined(separator: "\n")).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    model.selection = .reviews
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // helpers

    private var visible: [ImportCandidate] {
        guard let filter else { return candidates }
        return candidates.filter { $0.status == filter }
    }

    private func count(_ s: ImportStatus) -> Int { candidates.filter { $0.status == s }.count }

    private func filterButton(_ s: ImportStatus?, _ label: String, _ n: Int) -> some View {
        Button("\(label) \(n)") { filter = s }
            .buttonStyle(.bordered)
            .tint(filter == s ? .accentColor : nil)
    }

    private func binding(for c: ImportCandidate) -> Binding<Bool> {
        Binding(
            get: { candidates.first { $0.id == c.id }?.include ?? false },
            set: { v in if let i = candidates.firstIndex(where: { $0.id == c.id }) { candidates[i].include = v } }
        )
    }

    private func scan() async {
        guard let service = model.service else { return }
        error = nil
        phase = .scanning
        progress = "Reading notes..."
        do {
            let notes = try service.scanVaultForImport()
            progress = "Matching \(notes.count) notes on TMDB..."
            candidates = try await service.matchImport(notes) { done, total in
                Task { @MainActor in progress = "Matching \(done) of \(total) on TMDB..." }
            }
            phase = .review
        } catch {
            self.error = error.localizedDescription
            phase = .intro
        }
    }

    private func apply() async {
        guard let service = model.service else { return }
        error = nil
        phase = .applying
        progress = "Backing up and importing..."
        do {
            summary = try await service.applyImport(candidates, addRunningShows: addShows) { done, total in
                Task { @MainActor in progress = "Importing \(done) of \(total)..." }
            }
            model.reload()
            phase = .done
        } catch {
            self.error = error.localizedDescription
            phase = .review
        }
    }
}

struct ImportRow: View {
    let candidate: ImportCandidate
    @Binding var include: Bool
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $include)
                .labelsHidden()
                .disabled(![.ready, .check].contains(candidate.status))
            Image(systemName: candidate.mediaType == .movie ? "film" : "tv").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.noteName).lineLimit(1)
                Text(matchText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            statusLabel
            if [.check, .unmatched, .ready].contains(candidate.status) {
                Button("Fix") { fix() }.buttonStyle(.link)
            }
        }
        .padding(.vertical, 1)
    }

    private var matchText: String {
        guard let m = candidate.match else { return candidate.note ?? "No match on TMDB" }
        var t = "\(m.title)\(m.year.map { " (\($0))" } ?? "")"
        if candidate.mediaType == .tv { t += ", season \(candidate.season)" }
        t += " via \(m.via)"
        if let note = candidate.note { t += ". \(note)" }
        if let rename = candidate.renameTo { t += ". Rename to \"\(rename)\"" }
        return t
    }

    private var statusLabel: some View {
        let (text, color): (String, Color) = {
            switch candidate.status {
            case .ready: return ("Matched", .green)
            case .check: return ("Check", .orange)
            case .unmatched: return ("No match", .secondary)
            case .alreadyLinked: return ("Linked", .blue)
            case .duplicate: return ("Duplicate", .red)
            }
        }()
        return Text(text).font(.caption.bold()).foregroundStyle(color)
    }
}

/// search tmdb and pick the right title for one note
struct FixMatchSheet: View {
    @Environment(AppModel.self) private var model
    let candidate: ImportCandidate
    let done: (SearchResult?, String?) -> Void
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var selected: Int?
    @State private var searching = false
    @State private var rename = false
    @State private var newName = ""
    @State private var links: [(path: String, count: Int)]?
    @State private var namesake = false

    private var choice: SearchResult? { results.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match \"\(candidate.noteName)\"").font(.headline)
            HStack {
                TextField("Search TMDB", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
            }
            List(results, selection: $selected) { r in
                ResultRow(result: r, saved: false).tag(r.id)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .onChange(of: selected) { _, _ in suggest() }

            Toggle("Rename the note in Obsidian", isOn: $rename)
            if rename {
                TextField("New note name", text: $newName).textFieldStyle(.roundedBorder)
                Group {
                    if namesake {
                        Text("Another note is also named \"\(candidate.noteName)\", so links to that name are ambiguous and will be left as they are.")
                    } else if let links {
                        let total = links.reduce(0) { $0 + $1.count }
                        Text(total == 0
                             ? "No other notes link to \"\(candidate.noteName)\"."
                             : "\(total) link\(total == 1 ? "" : "s") in \(links.count) note\(links.count == 1 ? "" : "s") point to \"\(candidate.noteName)\" and will be updated, like a rename in Obsidian.")
                    } else {
                        Text("Counting links...")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                if searching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { done(nil, nil) }.keyboardShortcut(.cancelAction)
                Button(rename ? "Use This and Rename" : "Use This") {
                    done(choice, rename ? newName.trimmingCharacters(in: .whitespaces) : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || (rename && newName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(16)
        .frame(width: 560, height: 540)
        .onChange(of: rename) { _, on in
            if on && links == nil {
                links = (try? model.service?.linkReferences(to: candidate.noteName)) ?? []
                if let vault = ObsidianVault.resolve(model.config) {
                    namesake = NoteRename.hasNamesake(candidate.noteName, otherThan: vault.appendingPathComponent(candidate.relativePath), in: vault)
                }
            }
        }
        .task {
            query = candidate.searchName
            await search()
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        results = (try? await model.search(query)) ?? []
        selected = results.first { $0.kind == candidate.mediaType }?.id ?? results.first?.id
        suggest()
    }

    private func suggest() {
        guard let choice else { return }
        newName = NoteRename.suggestedName(for: candidate, title: choice.displayTitle)
    }
}
