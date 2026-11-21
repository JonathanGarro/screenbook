import SwiftUI
import WatchlistCore

// detail

struct TitleDetailView: View {
    @Environment(AppModel.self) private var model
    let title: Title
    @State private var providers: ProviderInfo?
    @State private var loadedProviders = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let overview = title.overview, !overview.isEmpty {
                    Text(overview)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if title.mediaType == .movie {
                    movieWatchSection
                }
                if model.config.streamingEnabled {
                    streamingSection
                }
                if title.mediaType == .tv {
                    EpisodesSection(title: title)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh(title) }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Refresh this title from TMDB")
                Button(role: .destructive) {
                    model.remove(title)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove from watchlist")
            }
        }
        .task(id: title.id) {
            if model.config.streamingEnabled && !loadedProviders {
                providers = await model.providers(title)
                loadedProviders = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Poster(url: title.posterURL, width: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text(title.title).font(.largeTitle.bold()).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(title.mediaType.label)
                    if let y = title.year { Text(String(y)) }
                    if let s = title.status { Text(s) }
                }
                .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    switch title.mediaType {
                    case .movie:
                        fact("\(model.config.region) release", title.regionReleaseDate)
                        fact("Digital", title.digitalReleaseDate)
                    case .tv:
                        fact("First aired", title.regionReleaseDate)
                        if let last = title.lastAired {
                            fact("Latest episode", "\(last.code), \(DateText.pretty(title.lastAiredDate))")
                        }
                        if title.allAvailable {
                            fact("Next episode", "All listed episodes treated as out")
                        } else if let next = title.nextAir {
                            fact("Next episode", "\(next.code), \(DateText.pretty(title.nextAirDate))")
                        } else {
                            fact("Next episode", "None scheduled")
                        }
                        if let n = model.unwatched[title.id] {
                            fact("Unwatched", n == 0 ? "Caught up" : "\(n) aired episodes")
                        }
                    }
                    fact("Added", title.addedOn)
                }
                .font(.callout)

                if let url = title.tmdbURL {
                    Link("View on TMDB", destination: url).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value.count == 10 && value.dropFirst(4).first == "-" ? DateText.pretty(value) : value)
            }
        }
    }

    private var movieWatchSection: some View {
        let review = model.existingReview(title)
        return HStack(spacing: 12) {
            if let day = title.watchedOn {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                DatePicker("Watched on", selection: Binding(
                    get: { ReviewEditor.date(day) ?? Date() },
                    set: { model.setMovieWatched(title, on: DateText.day($0)) }
                ), displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
                Button("Unmark") { model.setMovieWatched(title, on: nil) }
                    .buttonStyle(.link)
            } else {
                Button {
                    model.setMovieWatched(title, on: model.today)
                } label: {
                    Label("Mark Watched", systemImage: "checkmark.circle")
                }
            }
            Spacer()
            if let review {
                StarsLabel(rating: review.rating)
                Text(review.isSent ? "In Obsidian" : "Draft").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.openReview(title)
            } label: {
                Label(review == nil ? "Write Review" : "Edit Review", systemImage: "square.and.pencil")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where to Watch (\(model.config.region))").font(.headline)
            if !loadedProviders {
                ProgressView().controlSize(.small)
            } else {
                let streams = providers?.flatrate ?? []
                let extra = model.config.includeRentBuy ? (providers?.rent ?? []) + (providers?.buy ?? []) : []
                if streams.isEmpty && extra.isEmpty {
                    Text("Not on a subscription service in \(model.config.region).").foregroundStyle(.secondary)
                } else {
                    ProviderStrip(label: "Stream", providers: streams)
                    if model.config.includeRentBuy {
                        ProviderStrip(label: "Rent", providers: providers?.rent ?? [])
                        ProviderStrip(label: "Buy", providers: providers?.buy ?? [])
                    }
                }
                HStack(spacing: 6) {
                    Text(Attribution.justWatch)
                    if let link = providers?.link, let url = URL(string: link) {
                        Link("Details", destination: url)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProviderStrip: View {
    let label: String
    let providers: [Provider]

    var body: some View {
        if !providers.isEmpty {
            HStack(spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                ForEach(providers.sorted { ($0.displayPriority ?? 999) < ($1.displayPriority ?? 999) }, id: \.providerId) { p in
                    AsyncImage(url: p.logoURL) { img in
                        img.resizable()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(p.providerName)
                }
            }
        }
    }
}

// episodes

struct EpisodesSection: View {
    @Environment(AppModel.self) private var model
    let title: Title
    @State private var season: Int = 1
    @State private var episodes: [EpisodeDetail] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        let seasons = model.seasons(title).filter { $0.seasonNumber > 0 }
        let watched = model.watched(title)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Episodes").font(.headline)
                Spacer()
                if !seasons.isEmpty {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.seasonNumber) { s in
                            Text(s.name ?? "Season \(s.seasonNumber)").tag(s.seasonNumber)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                let seasonReview = model.existingReview(title, season: season)
                Button {
                    model.openReview(title, season: season)
                } label: {
                    Label(seasonReview == nil ? "Review Season" : (seasonReview!.isSent ? "Edit Review" : "Edit Draft"),
                          systemImage: "square.and.pencil")
                }
                .help("Write a review of this season for Obsidian")
                Menu {
                    Button("Mark Season Watched") {
                        model.setWatched(title, aired.map(\.ref), watched: true)
                    }
                    Button("Mark Season Unwatched") {
                        model.setWatched(title, episodes.map(\.ref), watched: false)
                    }
                    if let last = (try? model.service?.effectiveLastAired(title)) ?? title.lastAired {
                        Divider()
                        Button("Mark All Aired Watched (through \(last.code))") {
                            Task { await model.markUpTo(title, last) }
                        }
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Toggle(isOn: Binding(get: { title.allAvailable }, set: { model.setAllAvailable(title, $0) })) {
                Text("All episodes are out")
                Text("For shows a streaming service released all at once. TMDB only lists original broadcast dates.")
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            if loading {
                ProgressView().controlSize(.small)
            } else if let loadError {
                Text(loadError).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(episodes) { ep in
                        EpisodeRow(episode: ep, watched: watched.contains(ep.ref), aired: isAired(ep)) { newValue in
                            model.setWatched(title, [ep.ref], watched: newValue)
                        }
                        .contextMenu {
                            Button("Mark Watched Up to Here") {
                                Task { await model.markUpTo(title, ep.ref) }
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .task(id: season) {
            await load()
        }
        .onAppear {
            // open on the season with the first unwatched episode, else the latest aired season
            let unwatchedFirst = (try? model.service?.unwatchedAired(title).first) ?? nil
            if let s = unwatchedFirst?.season ?? title.lastAiredSeason ?? seasons.last?.seasonNumber {
                season = s
            }
        }
    }

    private var aired: [EpisodeDetail] { episodes.filter(isAired) }

    private func isAired(_ ep: EpisodeDetail) -> Bool {
        if title.allAvailable { return true }
        guard let d = DateText.normalize(ep.airDate) else { return false }
        return d <= model.today
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            episodes = try await model.episodes(title, season: season)
        } catch {
            episodes = []
            loadError = error.localizedDescription
        }
    }
}

struct EpisodeRow: View {
    let episode: EpisodeDetail
    let watched: Bool
    let aired: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                toggle(!watched)
            } label: {
                Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(watched ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(watched ? "Mark unwatched" : "Mark watched")

            Text(episode.ref.code)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(episode.name ?? "Episode \(episode.episodeNumber)")
                .lineLimit(1)
            Spacer()
            Text(episode.airDate.map { DateText.pretty(DateText.normalize($0)) } ?? "TBA")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .opacity(aired ? 1 : 0.5)
    }
}
