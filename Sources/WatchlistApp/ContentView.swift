import SwiftUI
import WatchlistCore

// main window

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List {
                ForEach(SidebarItem.allCases) { item in
                    let on = model.selection == item
                    HStack(spacing: 0) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                            .padding(.trailing, 8)
                        Text(item.label)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 4)
                        if let n = model.count(for: item) {
                            Text("\(n)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.sidebarSelection : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectSection(item) }
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
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
                    ToWatchList()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if model.selection == .insights {
                InsightsView()
            } else if model.selection == .whatsNew && model.selectedTitleID == nil {
                CalendarView()
            } else if let t = model.title(model.selectedTitleID) {
                TitleDetailView(title: t)
                    .id(t.id)
            } else if model.selection == .library, let e = model.libraryEntry(model.selectedTitleID) {
                if let note = e.note {
                    UnlinkedNoteView(note: note)
                        .id(e.id)
                } else {
                    HistoryDetailView(entry: e)
                        .id(e.id)
                }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "film.stack",
                                       description: Text("Pick a title to see dates, episodes, and where to watch."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.selection == .whatsNew && model.selectedTitleID != nil {
                    Button {
                        model.selectedTitleID = nil
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                    .help("Back to the calendar")
                }
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
        .tint(Theme.accent)
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
            SettingsLink {
                HStack(spacing: 0) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                        .padding(.trailing, 8)
                    Text("Settings")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .help("Settings (Cmd+,)")
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
            Text("Screenbook needs a free TMDB API key or read access token. Get one at themoviedb.org under Settings, API, then paste it in Settings here.")
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
            List(items) { t in
                TitleRow(title: t)
                    .selectableRow(t.id, selection: $model.selectedTitleID)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .arrowSelection(items.map(\.id), selection: $model.selectedTitleID)
        }
    }
}

struct TitleRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.rowSelected) private var selected
    let title: Title
    var detail: String? = nil
    /// your latest rating, shown at the trailing edge when present
    var rating: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            Poster(url: title.posterURL, width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.title).font(.headline).lineLimit(2)
                Text([title.year.map(String.init), detail ?? subtitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            RowTrailing(type: title.mediaType, rating: rating)
            if let n = model.unwatched[title.id], n > 0 {
                CountBadge(count: n)
                    .help("\(n) aired episodes unwatched")
            }
        }
    }

    private var subtitle: String {
        let today = model.today
        if let stopped = title.stoppedOn {
            return "Stopped \(DateText.pretty(stopped))"
        }
        switch title.mediaType {
        case .movie:
            if let w = title.watchedOn { return "Watched \(DateText.pretty(w))" }
            if let d = title.regionReleaseDate, d > today { return "Releases \(DateText.pretty(d))" }
            if let d = title.digitalReleaseDate, d > today { return "Digital \(DateText.pretty(d))" }
            if let d = title.regionReleaseDate { return "Released \(DateText.pretty(d))" }
            return "No date yet"
        case .tv:
            if title.allAvailable {
                return "All episodes out"
            }
            if let d = title.nextAirDate {
                return "\(title.nextAir?.code ?? "Next") on \(DateText.pretty(d))"
            }
            return title.status ?? "No upcoming episode"
        }
    }
}

/// the right side of a title row: your rating above a tv or movie pill
struct RowTrailing: View {
    @Environment(\.rowSelected) private var selected
    let type: MediaType
    var rating: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let rating {
                Text(myLabel(rating)).font(.caption).foregroundStyle(selected ? Color.white : .yellow)
            }
            Text(type == .tv ? "TV" : "Movie")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15)))
        }
        .fixedSize()
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
        List {
            if let r = model.report {
                Section("Released Since Last Check") {
                    if r.releasedMovies.isEmpty {
                        Text("No new releases").foregroundStyle(.secondary)
                    }
                    ForEach(r.releasedMovies, id: \.id) { t in
                        TitleRow(title: current(t), detail: "Released \(DateText.pretty(t.regionReleaseDate))")
                            .selectableRow(t.id, selection: $model.selectedTitleID)
                    }
                }
                if !model.config.myServices.isEmpty {
                    Section("Now on Your Services") {
                        if r.newlyStreaming.isEmpty {
                            Text("Nothing new on your services").foregroundStyle(.secondary)
                        }
                        ForEach(r.newlyStreaming, id: \.title.id) { u in
                            TitleRow(title: current(u.title), detail: "On " + ListFormatter.localizedString(byJoining: u.services))
                                .selectableRow(u.title.id, selection: $model.selectedTitleID)
                        }
                    }
                }
                Section("New Episodes") {
                    if r.newEpisodeShows.isEmpty {
                        Text("No new episodes").foregroundStyle(.secondary)
                    }
                    ForEach(r.newEpisodeShows, id: \.title.id) { u in
                        TitleRow(title: current(u.title), detail: u.newlyAired.map(\.code).joined(separator: ", "))
                            .selectableRow(u.title.id, selection: $model.selectedTitleID)
                    }
                }
            } else {
                Section {
                    Button("Check Now") { Task { await model.check() } }
                        .disabled(model.isChecking || model.titles.isEmpty)
                } footer: {
                    Text("Run a check to see new releases and episodes.")
                }
            }
            Section("Coming Up, Next 30 Days") {
                if model.calendarEvents.isEmpty {
                    Text(model.calendarLoading ? "Loading..." : "Nothing scheduled").foregroundStyle(.secondary)
                }
                ForEach(model.calendarEvents) { e in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shortDay(e.date)).font(.caption.bold())
                            Text(weekday(e.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 52, alignment: .leading)
                        Circle().fill(CalendarColors.color(e.mediaType)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).lineLimit(1)
                            Text(e.episodeName.map { "\(e.label), \($0)" } ?? e.label)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .selectableRow(e.titleId, selection: $model.selectedTitleID)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: model.titles.count) { await model.loadCalendar() }
    }

    /// prefer the live row so badges reflect episodes watched since the check
    private func current(_ t: Title) -> Title {
        model.title(t.id) ?? t
    }
}

// to watch, with a type filter

struct ToWatchList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let all = model.items(for: .unwatched)
        let items = all.filter { t in
            switch model.toWatchType {
            case .all: return true
            case .movies: return t.mediaType == .movie
            case .tv: return t.mediaType == .tv
            }
        }
        VStack(spacing: 0) {
            Picker("Type", selection: $model.toWatchType) {
                ForEach(LibraryType.allCases) { type in
                    let n = type == .all ? all.count : all.filter { (type == .movies) == ($0.mediaType == .movie) }.count
                    Text("\(type.rawValue) \(n)").tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            TitleList(items: items)
        }
    }
}
