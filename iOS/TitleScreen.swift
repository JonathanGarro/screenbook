import SwiftUI
import WatchlistCore

// one title: details, then episode checkmarks for a show or a watched switch for a movie

struct TitleScreen: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmRemove = false

    var body: some View {
        if let t = model.title(id) {
            List {
                header(t)
                if t.mediaType == .tv {
                    EpisodesSection(title: t)
                } else {
                    Section {
                        Toggle("Watched", isOn: Binding(
                            get: { t.watchedOn != nil }, set: { model.setMovieWatched(t, $0) }))
                        if let d = t.watchedOn {
                            LabeledContent("Watched on", value: Dates.short(d))
                        }
                    }
                }
                Section {
                    Button(t.isStopped ? "Resume Watching" : "Stop Watching") {
                        Task { await model.setStopped(t, !t.isStopped) }
                    }
                    Button("Remove from Watchlist", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(t.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove \(t.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    model.remove(t)
                    dismiss()
                }
            } message: {
                Text("This removes it and its watched episodes on all your devices.")
            }
        } else {
            ContentUnavailableView("Not on your watchlist", systemImage: "film")
        }
    }

    private func header(_ t: Title) -> some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Poster(url: t.posterURL, width: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.title).font(.title3.bold())
                    Text(meta(t)).font(.subheadline).foregroundStyle(.secondary)
                    Text(model.status(t).rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
            if let overview = t.overview, !overview.isEmpty {
                Text(overview).font(.callout)
            }
            if let next = t.nextDate(today: model.today) {
                LabeledContent(t.mediaType == .tv ? "Next episode" : "Release",
                               value: [t.mediaType == .tv ? t.nextAir?.code : nil, Dates.short(next)]
                                .compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private func meta(_ t: Title) -> String {
        [t.mediaType == .tv ? "TV" : "Movie", t.year.map(String.init), t.status].compactMap { $0 }.joined(separator: " · ")
    }
}

// episodes

struct EpisodesSection: View {
    @Environment(PhoneModel.self) private var model
    let title: Title
    @State private var season: Int?
    @State private var episodes: [EpisodeDetail] = []
    @State private var loading = false

    var body: some View {
        let seasons = model.seasons(title).filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
        let seen = model.watched[title.id] ?? []
        Section {
            if loading && episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(episodes) { ep in
                let on = seen.contains(ep.ref)
                Button {
                    model.setEpisode(title, ep.ref, watched: !on)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ep.episodeNumber). \(ep.name ?? "Episode \(ep.episodeNumber)")")
                                .foregroundStyle(.primary)
                            if let d = ep.airDate.flatMap(DateText.normalize) {
                                Text(d > model.today ? "Airs \(Dates.short(d))" : Dates.short(d))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Mark Watched Up to Here", systemImage: "checkmark.circle") {
                        Task { await model.markUpTo(title, ep.ref) }
                    }
                }
            }
        } header: {
            HStack {
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.seasonNumber) { s in
                            Button(s.name ?? "Season \(s.seasonNumber)") { season = s.seasonNumber }
                        }
                    } label: {
                        Label(seasonName(seasons), systemImage: "chevron.up.chevron.down")
                            .labelStyle(TrailingIconLabel())
                    }
                } else {
                    Text(seasonName(seasons))
                }
                Spacer()
                Menu {
                    let aired = episodes.filter { ($0.airDate.flatMap(DateText.normalize) ?? "9999") <= model.today }.map(\.ref)
                    Button("Mark Season Watched", systemImage: "checkmark.circle") { model.setSeason(title, aired, watched: true) }
                    Button("Mark Season Unwatched", systemImage: "circle") { model.setSeason(title, episodes.map(\.ref), watched: false) }
                    Toggle("All Episodes Are Out", isOn: Binding(
                        get: { title.allAvailable }, set: { model.setAllAvailable(title, $0) }))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        } footer: {
            Text("Touch and hold an episode to mark everything up to it.")
        }
        .task(id: season) { await load(seasons) }
    }

    private func seasonName(_ seasons: [SeasonSummary]) -> String {
        guard let n = season ?? seasons.first?.seasonNumber else { return "Episodes" }
        return seasons.first { $0.seasonNumber == n }?.name ?? "Season \(n)"
    }

    /// opens on the first season with something unwatched
    private func load(_ seasons: [SeasonSummary]) async {
        if season == nil {
            let seen = model.watched[title.id] ?? []
            let firstOpen = seasons.first { s in
                (1...max(1, s.episodeCount)).contains { !seen.contains(EpisodeRef(season: s.seasonNumber, episode: $0)) }
            }
            season = firstOpen?.seasonNumber ?? seasons.last?.seasonNumber
            if season != nil { return }
        }
        guard let n = season else { return }
        loading = true
        let list = await model.episodes(title, season: n)
        if season == n { episodes = list }
        loading = false
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
