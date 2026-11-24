import SwiftUI
import WatchlistCore

// what's new

struct WhatsNewView: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSettings = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) { content }
            .onAppear {
                // debug launch argument for screenshots, e.g. -openTitle tv-1396
                if path.isEmpty, let id = UserDefaults.standard.string(forKey: "openTitle") { path = [id] }
            }
    }

    private var content: some View {
        List {
            if !model.hasKey {
                Section {
                    Button("Add your TMDB key") { showSettings = true }
                } footer: {
                    Text("Episodes, posters and release dates come from TMDB. Your key syncs from your Mac through iCloud, or you can add it here.")
                }
            }
            Section("New Episodes") {
                if model.newEpisodes.isEmpty {
                    Text("You're caught up.").foregroundStyle(.secondary)
                }
                ForEach(model.newEpisodes) { t in
                    NavigationLink(value: t.id) {
                        TitleRow(title: t, detail: newDetail(t))
                    }
                }
            }
            Section("Coming Up") {
                if model.upcoming.isEmpty {
                    Text("Nothing in the next two months.").foregroundStyle(.secondary)
                }
                ForEach(model.upcoming, id: \.title.id) { item in
                    NavigationLink(value: item.title.id) {
                        TitleRow(title: item.title, detail: upcomingDetail(item.title, item.date))
                    }
                }
            }
        }
        .navigationTitle("What's New")
        .navigationDestination(for: String.self) { id in TitleScreen(id: id) }
        .refreshable { await model.check() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func newDetail(_ t: Title) -> String {
        let n = model.unwatched[t.id] ?? 0
        var s = n == 1 ? "1 episode" : "\(n) episodes"
        if let d = t.lastAiredDate { s += " · latest " + Dates.short(d) }
        return s
    }

    private func upcomingDetail(_ t: Title, _ date: String) -> String {
        if t.mediaType == .tv, let next = t.nextAir { return "\(next.code) · \(Dates.short(date))" }
        return "Movie · \(Dates.short(date))"
    }
}

// to watch

struct ToWatchView: View {
    @Environment(PhoneModel.self) private var model
    @State private var type: MediaType?

    var body: some View {
        let items = model.toWatch.filter { type == nil || $0.mediaType == type }
        List {
            Picker("Type", selection: $type) {
                Text("All").tag(MediaType?.none)
                Text("TV").tag(MediaType?.some(.tv))
                Text("Movies").tag(MediaType?.some(.movie))
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if !model.hasKey {
                NeedsKeyNote()
            } else if items.isEmpty {
                Text("Nothing to watch right now.").foregroundStyle(.secondary)
            }
            ForEach(items) { t in
                NavigationLink(value: t.id) {
                    TitleRow(title: t, detail: detail(t))
                }
            }
        }
        .navigationTitle("To Watch")
        .navigationDestination(for: String.self) { id in TitleScreen(id: id) }
        .refreshable { await model.check() }
    }

    private func detail(_ t: Title) -> String {
        switch t.mediaType {
        case .tv:
            let n = model.unwatched[t.id] ?? 0
            return n == 1 ? "1 episode" : "\(n) episodes"
        case .movie:
            return ["Movie", t.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

// library

struct LibraryView: View {
    @Environment(PhoneModel.self) private var model
    @State private var status: PhoneStatus = .all
    @State private var type: MediaType?
    @State private var search = ""

    var body: some View {
        let items = model.library(status, type: type, search: search)
        List {
            if !model.hasKey { NeedsKeyNote() }
            if items.isEmpty {
                Text(search.isEmpty ? "Nothing here." : "No matches.").foregroundStyle(.secondary)
            }
            ForEach(items) { t in
                NavigationLink(value: t.id) {
                    TitleRow(title: t, detail: detail(t))
                }
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: String.self) { id in TitleScreen(id: id) }
        .searchable(text: $search, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $status) {
                        ForEach(PhoneStatus.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Type", selection: $type) {
                        Text("Movies and TV").tag(MediaType?.none)
                        Text("TV").tag(MediaType?.some(.tv))
                        Text("Movies").tag(MediaType?.some(.movie))
                    }
                } label: {
                    Label("Filter", systemImage: status == .all && type == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }

    private func detail(_ t: Title) -> String {
        let kind = t.mediaType == .tv ? "TV" : "Movie"
        return [kind, t.year.map(String.init), model.status(t).rawValue].compactMap { $0 }.joined(separator: " · ")
    }
}

// shown until a tmdb key is saved: titles sync from the mac, but episode data comes from tmdb

struct NeedsKeyNote: View {
    var body: some View {
        Text("Episodes and release dates need a TMDB key. It syncs from your Mac through iCloud, or add it in Settings, the gear on What's New.")
            .font(.subheadline).foregroundStyle(.secondary)
    }
}

// rows

struct TitleRow: View {
    let title: Title
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Poster(url: title.posterURL, width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.title).font(.body.weight(.medium)).lineLimit(2)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width / 10))
    }
}

enum Dates {
    /// "Mar 4" this year, "Mar 4, 2027" otherwise
    static func short(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        return d.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
