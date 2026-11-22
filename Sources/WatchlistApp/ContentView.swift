import SwiftUI
import WatchlistCore

// main window

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.label, systemImage: item.symbol)
                    .badge(model.count(for: item) ?? 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusFooter() }
        } content: {
            Group {
                if !model.hasKey {
                    NoKeyView()
                } else if model.selection == .whatsNew {
                    WhatsNewList()
                } else if model.selection == .library {
                    LibraryList()
                } else if model.selection == .reviews {
                    ReviewsList()
                } else if model.selection == .insights {
                    InsightsTable()
                } else {
                    TitleList(items: model.items(for: model.selection ?? .upcoming))
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if model.selection == .insights {
                InsightsView()
            } else if let t = model.title(model.selectedTitleID) {
                TitleDetailView(title: t)
                    .id(t.id)
            } else if model.selection == .library, let e = model.libraryEntry(model.selectedTitleID) {
                HistoryDetailView(entry: e)
                    .id(e.id)
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "film.stack",
                                       description: Text("Pick a title to see dates, episodes, and where to watch."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.check() }
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .help("Refresh every title from TMDB")
                .disabled(!model.hasKey || model.isChecking)

                Button {
                    model.showingAdd = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Search TMDB and add a title")
                .disabled(!model.hasKey)
            }
        }
        .task {
            model.openWindowAction = openWindow
            await model.checkOnLaunchIfNeeded()
        }
        .sheet(isPresented: $model.showingAdd) {
            AddTitleSheet()
        }
        .sheet(item: $model.editingReview) { r in
            ReviewEditor(review: r)
        }
        .sheet(isPresented: $model.showingImport) {
            ImportSheet()
        }
        .sheet(isPresented: $model.showingFillRatings) {
            FillRatingsSheet()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// footer

struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isChecking {
                Text(model.progressText)
                    .lineLimit(2)
            } else if let r = model.report {
                Text("Last checked \(r.checkedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Not checked yet")
            }
            Text("Data: TMDB")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

// empty state

struct NoKeyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Add Your TMDB Key", systemImage: "key")
        } description: {
            Text("Watchlist needs a free TMDB API key or read access token. Get one at themoviedb.org under Settings, API, then paste it in Settings here.")
        } actions: {
            SettingsLink {
                Text("Open Settings")
            }
        }
    }
}

// title list

struct TitleList: View {
    @Environment(AppModel.self) private var model
    let items: [Title]

    var body: some View {
        @Bindable var model = model
        if items.isEmpty {
            ContentUnavailableView {
                Label("Nothing Here", systemImage: "tray")
            } description: {
                Text(model.titles.isEmpty ? "Add a movie or show to start tracking it." : "No titles match this view.")
            } actions: {
                if model.titles.isEmpty {
                    Button("Add Title") { model.showingAdd = true }
                }
            }
        } else {
            List(items, selection: $model.selectedTitleID) { t in
                TitleRow(title: t)
                    .tag(t.id)
                    .contextMenu {
                        Button("Refresh") { Task { await model.refresh(t) } }
                        if t.isStopped {
                            Button("Resume Watching") { Task { await model.setStopped(t, false) } }
                        } else {
                            Button(t.mediaType == .tv ? "Stop Watching" : "Stop Tracking") { Task { await model.setStopped(t, true) } }
                        }
                        if let url = t.tmdbURL {
                            Link("Open on TMDB", destination: url)
                        }
                        Divider()
                        Button("Remove", role: .destructive) { model.remove(t) }
                    }
            }
        }
    }
}

struct TitleRow: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var detail: String? = nil
    /// your latest rating, shown at the trailing edge when present
    var rating: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            Poster(url: title.posterURL, width: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title.title).font(.headline).lineLimit(1)
                    if let y = title.year {
                        Text(String(y)).foregroundStyle(.secondary)
                    }
                }
                Text(detail ?? subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let rating {
                Text(myLabel(rating)).font(.caption).foregroundStyle(.yellow)
            }
            if let n = model.unwatched[title.id], n > 0 {
                Text("\(n)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .help("\(n) aired episodes unwatched")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let today = model.today
        if let stopped = title.stoppedOn {
            return "\(title.mediaType.label), stopped \(DateText.pretty(stopped))"
        }
        switch title.mediaType {
        case .movie:
            if let w = title.watchedOn { return "Movie, watched \(DateText.pretty(w))" }
            if let d = title.regionReleaseDate, d > today { return "Movie, releases \(DateText.pretty(d))" }
            if let d = title.digitalReleaseDate, d > today { return "Movie, digital \(DateText.pretty(d))" }
            if let d = title.regionReleaseDate { return "Movie, released \(DateText.pretty(d))" }
            return "Movie, no date yet"
        case .tv:
            if title.allAvailable {
                return "TV, all episodes out"
            }
            if let d = title.nextAirDate {
                return "TV, \(title.nextAir?.code ?? "next") on \(DateText.pretty(d))"
            }
            return "TV, \(title.status ?? "no upcoming episode")"
        }
    }
}

struct Poster: View {
    let url: URL?
    let width: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width > 60 ? 8 : 4))
    }
}

// what's new

struct WhatsNewList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let r = model.report {
            List(selection: $model.selectedTitleID) {
                Section("Released Since Last Check") {
                    if r.releasedMovies.isEmpty {
                        Text("No new releases").foregroundStyle(.secondary)
                    }
                    ForEach(r.releasedMovies, id: \.id) { t in
                        TitleRow(title: current(t), detail: "Released \(DateText.pretty(t.regionReleaseDate))").tag(t.id)
                    }
                }
                Section("New Episodes") {
                    if r.newEpisodeShows.isEmpty {
                        Text("No new episodes").foregroundStyle(.secondary)
                    }
                    ForEach(r.newEpisodeShows, id: \.title.id) { u in
                        TitleRow(title: current(u.title), detail: u.newlyAired.map(\.code).joined(separator: ", ")).tag(u.title.id)
                    }
                }
                let upcoming = model.items(for: .upcoming).filter {
                    ($0.nextDate(today: model.today) ?? "9") <= DateText.addDays(model.today, 14)
                }
                if !upcoming.isEmpty {
                    Section("Next Two Weeks") {
                        ForEach(upcoming) { t in
                            TitleRow(title: t).tag(t.id)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Check Yet", systemImage: "sparkles")
            } description: {
                Text("Run a check to see new releases and episodes.")
            } actions: {
                Button("Check Now") { Task { await model.check() } }
                    .disabled(model.isChecking || model.titles.isEmpty)
            }
        }
    }

    /// prefer the live row so badges reflect episodes watched since the check
    private func current(_ t: Title) -> Title {
        model.title(t.id) ?? t
    }
}
