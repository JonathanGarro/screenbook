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
                if let stopped = title.stoppedOn {
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        Text("You stopped \(title.mediaType == .tv ? "watching" : "tracking") this on \(DateText.pretty(stopped)). Your progress is kept, and it is left out of Unwatched, Upcoming, notifications, and checks.")
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Resume") { Task { await model.setStopped(title, false) } }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
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
                let myReviews = model.reviews.filter { $0.tmdbId == title.tmdbId && $0.mediaType == title.mediaType }
                    .sorted { ($0.season, $0.finishedOn ?? "") < ($1.season, $1.finishedOn ?? "") }
                if !myReviews.isEmpty {
                    Text(myReviews.count == 1 ? "Your Review" : "Your Reviews").font(.system(size: 15, weight: .semibold))
                    ForEach(myReviews) { r in ReviewCard(review: r) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: 15))
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh(title) }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Refresh this title from TMDB")
                Button {
                    Task { await model.setStopped(title, !title.isStopped) }
                } label: {
                    Label(title.isStopped ? "Resume" : "Stop", systemImage: title.isStopped ? "play.circle" : "pause.circle")
                }
                .help(title.isStopped ? "Resume tracking" : (title.mediaType == .tv ? "Stop watching, keeping your progress" : "Stop tracking, keeping it saved"))
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
                Text(title.title).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                Text([title.mediaType.label, title.year.map(String.init), title.status].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)

                Divider().padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
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
                .font(.system(size: 14))
                Divider()

                if let url = title.tmdbURL {
                    Link("View on TMDB", destination: url).font(.system(size: 14)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).frame(minWidth: 110, alignment: .leading)
                Text(value.count == 10 && value.dropFirst(4).first == "-" ? DateText.pretty(value) : value)
            }
        }
    }

    private var movieWatchSection: some View {
        let review = model.existingReview(title)
        return HStack(spacing: 12) {
            if let day = title.watchedOn {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
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
                Text(review.isSent ? "In Obsidian" : "Draft").font(.system(size: 12)).foregroundStyle(.secondary)
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
            Text("Where to Watch (\(model.config.region))").font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 12))
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
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
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
    /// nil until the starting season is chosen, so nothing loads for the wrong season first
    @State private var chosenSeason: Int?
    @State private var episodes: [EpisodeDetail] = []
    @State private var loading = false
    @State private var loadError: String?

    private var season: Int { chosenSeason ?? 1 }

    var body: some View {
        let seasons = model.seasons(title).filter { $0.seasonNumber > 0 }
        let watched = model.watched(title)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // the season name doubles as the season picker
                Menu {
                    ForEach(seasons, id: \.seasonNumber) { s in
                        Button(s.name ?? "Season \(s.seasonNumber)") { chosenSeason = s.seasonNumber }
                    }
                } label: {
                    Text(seasons.first { $0.seasonNumber == season }?.name ?? "Season \(season)")
                        .font(.system(size: 19, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(seasons.count < 2)
                Spacer()
                let seasonReview = model.existingReview(title, season: season)
                Button(seasonReview == nil ? "Review Season" : (seasonReview!.isSent ? "Edit Review" : "Edit Draft")) {
                    model.openReview(title, season: season)
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .help("Write a review of this season for Obsidian")
                Menu {
                    Toggle("All Episodes Are Out", isOn: Binding(get: { title.allAvailable }, set: { model.setAllAvailable(title, $0) }))
                    Divider()
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
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mark watched, or treat every listed episode as out (for shows released all at once)")
            }
            if title.allAvailable {
                Text("All listed episodes are treated as out.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if loading || chosenSeason == nil {
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
        .task(id: chosenSeason) {
            if chosenSeason == nil {
                // open on the season with the first unwatched episode, else the latest aired season
                let unwatchedFirst = (try? model.service?.unwatchedAired(title).first) ?? nil
                chosenSeason = unwatchedFirst?.season ?? title.lastAiredSeason ?? seasons.last?.seasonNumber ?? 1
                return
            }
            await load()
        }
    }

    private var aired: [EpisodeDetail] { episodes.filter(isAired) }

    private func isAired(_ ep: EpisodeDetail) -> Bool {
        if title.allAvailable { return true }
        guard let d = DateText.normalize(ep.airDate) else { return false }
        return d <= model.today
    }

    private func load() async {
        guard let requested = chosenSeason else { return }
        loading = true
        loadError = nil
        do {
            let result = try await model.episodes(title, season: requested)
            // a newer load for another season owns the screen now
            guard !Task.isCancelled, requested == chosenSeason else { return }
            episodes = result
            loadError = nil
        } catch {
            guard !Task.isCancelled, requested == chosenSeason else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            episodes = []
            loadError = error.localizedDescription
        }
        loading = false
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
                    .font(.system(size: 18))
                    .foregroundStyle(watched ? Theme.accent : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(watched ? "Mark unwatched" : "Mark watched")

            Text(episode.ref.code)
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(episode.name ?? "Episode \(episode.episodeNumber)")
                .lineLimit(1)
            Spacer()
            Text(episode.airDate.map { DateText.pretty(DateText.normalize($0)) } ?? "TBA")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .opacity(aired ? 1 : 0.45)
    }
}
