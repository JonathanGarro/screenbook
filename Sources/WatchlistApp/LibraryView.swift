import SwiftUI
import WatchlistCore

// library list (middle column)

struct LibraryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let entries = model.filteredLibrary()
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Type", selection: $model.libraryType) {
                    ForEach(LibraryType.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Status", selection: $model.libraryStatus) {
                    ForEach(LibraryStatus.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("To Watch: available now. Waiting: caught up or not out yet. Watched: done, including your review history.")
                TextField("Search library", text: $model.librarySearch)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(10)

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Here", systemImage: "books.vertical")
                } description: {
                    Text(emptyText)
                }
                .frame(maxHeight: .infinity)
            } else {
                Text(model.librarySearch.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "\(entries.count) \(entries.count == 1 ? "title" : "titles")"
                     : "Searching all of your library: \(entries.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                List(entries) { e in
                    LibraryRow(entry: e, showStatus: !model.librarySearch.trimmingCharacters(in: .whitespaces).isEmpty)
                        .selectableRow(e.id, selection: $model.selectedTitleID)
                        .contextMenu { menu(e) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .arrowSelection(entries.map(\.id), selection: $model.selectedTitleID)
            }
        }
    }

    private var emptyText: String {
        if !model.librarySearch.isEmpty { return "No titles match your search." }
        switch model.libraryStatus {
        case .toWatch: return "Nothing to watch right now. Shows you are caught up on and movies not out yet are under Waiting."
        case .waiting: return "Shows you are caught up on and movies that are not out yet appear here, with their next date."
        case .watched: return "Movies you watch and shows you finish appear here, along with everything you have reviewed."
        case .stopped: return "Titles you stop watching appear here with their progress kept."
        case .all: return "Your library is empty."
        }
    }

    @ViewBuilder
    private func menu(_ e: LibraryEntry) -> some View {
        if let t = model.title(e.id) {
            Button("Refresh") { Task { await model.refresh(t) } }
            if t.isStopped {
                Button("Resume Watching") { Task { await model.setStopped(t, false) } }
            } else {
                Button(t.mediaType == .tv ? "Stop Watching" : "Stop Tracking") { Task { await model.setStopped(t, true) } }
            }
            Divider()
            Button("Remove from Watchlist", role: .destructive) { model.remove(t) }
        } else if e.note == nil {
            Button("Add to Watchlist") { Task { await model.addFromHistory(e) } }
        }
    }
}

struct LibraryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rowSelected) private var selected
    let entry: LibraryEntry
    var showStatus = false

    var body: some View {
        HStack(spacing: 6) {
            row
            if showStatus {
                Text(entry.status.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if let t = model.title(entry.id) {
            TitleRow(title: t, rating: entry.rating)
        } else if entry.note != nil {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
                    .frame(width: 36, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Text("\(entry.mediaType.label), not linked to TMDB").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let r = entry.rating { Text(myLabel(r)).font(.caption).foregroundStyle(.yellow) }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 10) {
                Poster(url: model.summaries[entry.id]?.posterURL, width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.headline).lineLimit(1)
                        if let y = model.summaries[entry.id]?.year { Text(String(y)).foregroundStyle(.secondary) }
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let r = entry.rating {
                    Text(myLabel(r)).font(.caption).foregroundStyle(selected ? Color.white : .yellow)
                }
            }
            .onAppear { model.loadSummary(entry) }
        }
    }

    private var subtitle: String {
        var parts = [entry.mediaType.label]
        if entry.mediaType == .tv {
            let seasons = Set(entry.reviews.map(\.season)).count
            parts.append("\(seasons) season\(seasons == 1 ? "" : "s") reviewed")
        }
        if let d = entry.finishedOn { parts.append("finished \(DateText.pretty(d))") }
        return parts.joined(separator: ", ")
    }
}

// detail for a title known only from your reviews

struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    @State private var adding = false

    var body: some View {
        let summary = model.summaries[entry.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    Poster(url: summary?.posterURL, width: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(entry.mediaType.label)
                            if let y = summary?.year { Text(String(y)) }
                            if let s = summary?.status, entry.mediaType == .tv { Text(s) }
                        }
                        .foregroundStyle(.secondary)
                        if let g = summary?.genres, !g.isEmpty {
                            Text(g.joined(separator: ", ")).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        Text("In your library from your reviews. It is not on your watchlist, so it is not checked for new releases or episodes.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Button {
                                adding = true
                                Task {
                                    await model.addFromHistory(entry)
                                    adding = false
                                }
                            } label: {
                                Label(adding ? "Adding..." : "Add to Watchlist", systemImage: "plus")
                            }
                            .disabled(adding || !model.hasKey)
                            Link("View on TMDB", destination: URL(string: "https://www.themoviedb.org/\(entry.mediaType.rawValue)/\(entry.tmdbId)")!)
                                .font(.system(size: 14))
                        }
                    }
                }
                if let overview = summary?.overview, !overview.isEmpty {
                    Text(overview).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.reviews.count == 1 ? "Your Review" : "Your Reviews").font(.system(size: 15, weight: .semibold))
                ForEach(entry.reviews.sorted { ($0.season, $0.finishedOn ?? "") < ($1.season, $1.finishedOn ?? "") }) { r in
                    ReviewCard(review: r)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 15))
        }
        .onAppear { model.loadSummary(entry) }
    }
}

struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let review: Review
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(review.mediaType == .tv ? review.noteTitle : "Review").font(.system(size: 14, weight: .bold))
                StarsLabel(rating: review.rating)
                if let d = review.finishedOn { Text(DateText.pretty(d)).foregroundStyle(.secondary) }
                Spacer()
                Button("Edit Review") { model.editingReview = review }
                    .buttonStyle(.link)
                if review.isSent {
                    Button("Open in Obsidian") {
                        error = nil
                        do { _ = try model.openInObsidian(review) } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.system(size: 14))
            if !review.body.isEmpty {
                Text(review.body)
                    .lineLimit(6)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}


// a vault note that is not linked yet

struct UnlinkedNoteView: View {
    @Environment(AppModel.self) private var model
    let note: ImportCandidate
    @State private var linking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(note.noteName).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(note.mediaType == .movie ? "Movie note" : "TV note")
                    StarsLabel(rating: note.rating)
                    if let d = note.finishedOn { Text(DateText.pretty(d)) }
                }
                .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link.badge.plus").foregroundStyle(.orange)
                    Text("This note is not linked to a TMDB title, so Screenbook cannot show its poster, add it to your watchlist, or include it in Insights. Link it to fix that; the note only gains a watchlist_id property (and a new name, if you choose one).")
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                HStack(spacing: 14) {
                    Button {
                        linking = true
                    } label: {
                        Label("Link to TMDB...", systemImage: "link")
                    }
                    .disabled(!model.hasKey)
                    if let vault = ObsidianVault.resolve(model.config),
                       let url = ObsidianVault.openURL(vault: vault, relativePath: note.relativePath) {
                        Link("Open in Obsidian", destination: url)
                    }
                }
                if !note.body.isEmpty {
                    Text(note.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 15))
        }
        .sheet(isPresented: $linking) {
            FixMatchSheet(candidate: note) { picked, renameTo in
                linking = false
                if let picked {
                    Task { _ = await model.linkNote(note, to: picked, renameTo: renameTo) }
                }
            }
        }
    }
}
