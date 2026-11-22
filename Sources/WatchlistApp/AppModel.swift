import AppKit
import Foundation
import Observation
import SwiftUI
import WatchlistCore

// sidebar

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case whatsNew, upcoming, unwatched, movies, shows, watched, all, stopped, reviews, insights

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whatsNew: return "What's New"
        case .upcoming: return "Upcoming"
        case .unwatched: return "Unwatched"
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .watched: return "Watched"
        case .all: return "Everything"
        case .stopped: return "Stopped"
        case .reviews: return "Reviews"
        case .insights: return "Insights"
        }
    }

    var symbol: String {
        switch self {
        case .whatsNew: return "sparkles"
        case .upcoming: return "calendar"
        case .unwatched: return "eye.slash"
        case .movies: return "film"
        case .shows: return "tv"
        case .watched: return "checkmark.circle"
        case .all: return "square.stack"
        case .stopped: return "pause.circle"
        case .reviews: return "star.bubble"
        case .insights: return "chart.dots.scatter"
        }
    }
}

// model

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let periodicInterval: TimeInterval = 6 * 3600

    var service: WatchlistService?
    var titles: [Title] = []
    var unwatched: [String: Int] = [:]
    /// observable copies of per-show db rows so episode checkmarks redraw immediately
    var watchedByTitle: [String: Set<EpisodeRef>] = [:]
    var seasonsByTitle: [String: [SeasonSummary]] = [:]
    var reviews: [Review] = []
    var editingReview: Review?
    var showingImport = false
    var showingFillRatings = false
    var reviewStates: [String: ReviewSyncState] = [:]
    var insightPoints: [RatingPoint] = []
    var insightSource: RatingSource = .rottenTomatoes
    var insightGenre: String?
    var insightsLoading = false
    var insightsProgress = ""
    var lastReviewSync: Date?
    private var activeObserver: NSObjectProtocol?
    var report: CheckReport?
    var selection: SidebarItem? = .whatsNew
    var selectedTitleID: String?
    var isChecking = false
    var progressText = ""
    var errorMessage: String?
    var showingAdd = false
    var hasKey = false
    var config = AppConfig()
    private var didLaunchCheck = false
    private var periodicTask: Task<Void, Never>?
    /// captured from a view so notification clicks can reopen a closed window
    var openWindowAction: OpenWindowAction?

    init() {
        open()
        // launch argument for opening on a given sidebar item, e.g. -startSelection insights
        if let start = UserDefaults.standard.string(forKey: "startSelection"), let item = SidebarItem(rawValue: start) {
            selection = item
        }
    }

    var paths: AppPaths { service?.paths ?? .standard() }
    var today: String { service?.today ?? DateText.day(Date()) }

    func open() {
        do {
            let s = try WatchlistService.standard()
            _ = try? s.markReviewedMoviesWatched()
            service = s
            config = s.config
            hasKey = s.client != nil
            report = s.lastReport
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() {
        guard let service else { return }
        do {
            titles = try service.titles()
            var counts: [String: Int] = [:]
            var watchedMap: [String: Set<EpisodeRef>] = [:]
            var seasonMap: [String: [SeasonSummary]] = [:]
            for t in titles where t.mediaType == .tv {
                // stopped shows keep their progress but do not count as unwatched
                counts[t.id] = t.isStopped ? 0 : try service.unwatchedAired(t).count
                watchedMap[t.id] = try service.db.watched(tmdbId: t.tmdbId)
                seasonMap[t.id] = try service.db.seasons(tmdbId: t.tmdbId)
            }
            unwatched = counts
            watchedByTitle = watchedMap
            seasonsByTitle = seasonMap
            reviews = try service.reviews()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func title(_ id: String?) -> Title? {
        guard let id else { return nil }
        return titles.first { $0.id == id }
    }

    // menu bar

    var totalUnwatched: Int { unwatched.values.reduce(0, +) }

    /// shows with unwatched aired episodes, most unwatched first
    var unwatchedShows: [(title: Title, count: Int)] {
        titles.compactMap { t in
            guard let n = unwatched[t.id], n > 0 else { return nil }
            return (t, n)
        }
        .sorted { $0.count == $1.count ? $0.title.title.lowercased() < $1.title.title.lowercased() : $0.count > $1.count }
    }

    // filtered lists

    func items(for item: SidebarItem) -> [Title] {
        let day = today
        let tracked = titles.filter { !$0.isStopped }
        let active = tracked.filter { !isFinished($0) }
        switch item {
        case .whatsNew, .reviews, .insights:
            return []
        case .upcoming:
            return tracked.filter { $0.nextDate(today: day) != nil }
                .sorted { ($0.nextDate(today: day) ?? "") < ($1.nextDate(today: day) ?? "") }
        case .unwatched:
            return tracked.filter { (unwatched[$0.id] ?? 0) > 0 }
        case .movies:
            return active.filter { $0.mediaType == .movie }
        case .shows:
            return active.filter { $0.mediaType == .tv }
        case .watched:
            return tracked.filter(isFinished).sorted { finishedDate($0) > finishedDate($1) }
        case .all:
            return titles
        case .stopped:
            return titles.filter(\.isStopped).sorted { ($0.stoppedOn ?? "") > ($1.stoppedOn ?? "") }
        }
    }

    /// watched movies, and shows that have ended with nothing left to watch
    func isFinished(_ t: Title) -> Bool {
        switch t.mediaType {
        case .movie:
            return t.watchedOn != nil
        case .tv:
            let ended = ["Ended", "Canceled", "Cancelled"].contains(t.status ?? "")
            return ended && (unwatched[t.id] ?? 0) == 0 && !(watchedByTitle[t.id] ?? []).isEmpty
        }
    }

    private func finishedDate(_ t: Title) -> String {
        t.watchedOn ?? t.lastAiredDate ?? ""
    }

    func count(for item: SidebarItem) -> Int? {
        switch item {
        case .whatsNew:
            guard let report else { return nil }
            let n = report.releasedMovies.count + report.newEpisodeShows.count
            return n > 0 ? n : nil
        case .unwatched:
            let n = items(for: .unwatched).count
            return n > 0 ? n : nil
        case .reviews:
            let n = reviews.filter { !$0.isSent }.count
            return n > 0 ? n : nil
        default:
            return nil
        }
    }

    // actions

    /// runs once per app launch when enabled; skipped without a key or with an empty list
    func checkOnLaunchIfNeeded() async {
        guard !didLaunchCheck else { return }
        didLaunchCheck = true
        startPeriodicChecks()
        Task { await syncReviews() }
        // pick up obsidian edits whenever the user switches back to watchlist
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncReviews() }
        }
        if config.notifyNewEpisodes || config.notifyMovieReleases {
            await Notifier.requestAuthorization()
        }
        guard config.checkOnLaunch, hasKey, !titles.isEmpty else { return }
        await check()
    }

    /// wakes every 15 minutes and checks once the last check is six hours old, so sleep and wake are handled
    func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self else { return }
                guard self.config.periodicCheck, self.hasKey, !self.titles.isEmpty, !self.isChecking else { continue }
                let last = self.report?.checkedAt ?? .distantPast
                if Date().timeIntervalSince(last) >= AppModel.periodicInterval {
                    await self.check()
                }
            }
        }
    }

    /// brings the main window forward on a title, used by notification clicks and the menu bar
    func openTitle(_ id: String?) {
        if let id, title(id) != nil {
            selection = .all
            selectedTitleID = id
        } else {
            selection = .whatsNew
        }
        openWindowAction?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func check(force: Bool = false) async {
        guard let service, !isChecking else { return }
        isChecking = true
        progressText = "Checking..."
        defer {
            isChecking = false
            progressText = ""
        }
        do {
            let r = try await service.check(force: force) { done, total, name in
                Task { @MainActor in self.progressText = "Checking \(done) of \(total): \(name)" }
            }
            report = r
            reload()
            if config.notifyNewEpisodes {
                await Notifier.post(r.newEpisodeShows)
            }
            if config.notifyMovieReleases {
                await Notifier.postReleases(r.releasedMovies, region: r.region)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(_ text: String) async throws -> [SearchResult] {
        guard let service else { return [] }
        return try await service.search(text)
    }

    func add(_ result: SearchResult, caughtUp: Bool) async -> Bool {
        guard let service else { return false }
        do {
            let t = try await service.add(result, caughtUp: caughtUp)
            reload()
            selectedTitleID = t.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func isSaved(_ result: SearchResult) -> Bool {
        titles.contains { $0.tmdbId == result.id && $0.mediaType.rawValue == result.mediaType }
    }

    func remove(_ t: Title) {
        guard let service else { return }
        do {
            try service.remove(t.tmdbId, t.mediaType)
            if selectedTitleID == t.id { selectedTitleID = nil }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setStopped(_ t: Title, _ stopped: Bool) async {
        guard let service else { return }
        do {
            try await service.setStopped(t.tmdbId, t.mediaType, stopped: stopped)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(_ t: Title) async {
        guard let service else { return }
        do {
            try await service.refresh(t, ttl: 0)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func watched(_ t: Title) -> Set<EpisodeRef> {
        watchedByTitle[t.id] ?? []
    }

    func seasons(_ t: Title) -> [SeasonSummary] {
        seasonsByTitle[t.id] ?? []
    }

    func setWatched(_ t: Title, _ eps: [EpisodeRef], watched: Bool) {
        guard let service else { return }
        do {
            try service.db.setWatched(tmdbId: t.tmdbId, eps, watched: watched, on: service.today)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markUpTo(_ t: Title, _ ep: EpisodeRef) async {
        guard let service else { return }
        do {
            try await service.markAllUpTo(t.tmdbId, season: ep.season, episode: ep.episode)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func episodes(_ t: Title, season: Int) async throws -> [EpisodeDetail] {
        guard let service else { return [] }
        return try await service.episodes(t, season: season)
    }

    func providers(_ t: Title) async -> ProviderInfo? {
        guard let service, config.streamingEnabled else { return nil }
        return try? await service.providers(t)
    }

    func writeDigest() async {
        guard let service else { return }
        if report == nil || DateText.day(report!.checkedAt) != today {
            await check()
        }
        guard let report else { return }
        do {
            let (url, _) = try service.writeDigest(report)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportCSV() {
        guard let service else { return }
        do {
            let url = try service.exportCSV()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.dataDir])
    }

    // reviews

    /// pulls obsidian edits into every sent review. skipped if it ran in the last few seconds unless forced.
    /// vault reads run off the main thread, so a slow disk or a pending macOS permission prompt never freezes the window
    @discardableResult
    func syncReviews(force: Bool = false) async -> SyncSummary? {
        guard let service, ObsidianVault.resolve(config) != nil, reviews.contains(where: \.isSent) || force else { return nil }
        if !force, let last = lastReviewSync, Date().timeIntervalSince(last) < 10 { return nil }
        lastReviewSync = Date()
        do {
            let summary = try await Task.detached { try service.syncReviewsFromObsidian() }.value
            reviewStates = summary.states
            if !summary.pulled.isEmpty { reload() }
            return summary
        } catch {
            return nil
        }
    }

    /// syncs one review, for the editor. force makes the note win over unsent edits.
    func syncOne(_ r: Review, force: Bool = false) async -> (Review, ReviewSyncState) {
        guard let service, r.isSent else { return (r, .inSync) }
        do {
            let result = try await Task.detached { try service.syncReview(r, force: force) }.value
            reviewStates[r.id] = result.state
            if result.pulled || result.review != r { reload() }
            return (result.review, result.state)
        } catch {
            return (r, reviewStates[r.id] ?? .inSync)
        }
    }

    /// loads ratings and genres for the insights chart
    func loadInsights(force: Bool = false) async {
        guard let service, !insightsLoading, force || insightPoints.isEmpty else { return }
        insightsLoading = true
        insightsProgress = "Reading your reviews..."
        defer { insightsLoading = false }
        do {
            insightPoints = try await service.ratingPoints { done, total in
                Task { @MainActor in self.insightsProgress = "Loading \(done) of \(total)" }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        insightsLoading = false
        renderInsightsIfRequested()
    }

    /// debug: -renderInsightsTo /path.png writes the insights view to an image (light and dark), for layout checks
    private func renderInsightsIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "renderInsightsTo") else { return }
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = InsightsContent(hover: HoverState())
                .environment(self)
                .frame(width: 1100)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
            }
        }
        NSApp.appearance = nil
    }

    /// opens the editor for a review by id
    func openReview(id: String) {
        if let r = reviews.first(where: { $0.id == id }) { editingReview = r }
    }

    func existingReview(_ t: Title, season: Int = 0) -> Review? {
        let s = t.mediaType == .movie ? 0 : season
        return reviews.first { $0.tmdbId == t.tmdbId && $0.mediaType == t.mediaType && $0.season == s }
    }

    func hasSavedReview(_ r: Review) -> Bool {
        reviews.contains { $0.id == r.id }
    }

    func openReview(_ t: Title, season: Int = 0) {
        guard let service else { return }
        do {
            var draft = try service.review(for: t, season: season)
            let isNew = !reviews.contains { $0.id == draft.id }
            editingReview = draft
            // new movie drafts get their place in a tmdb collection, e.g. 3 for the third film
            if isNew && t.mediaType == .movie {
                Task {
                    if let pos = try? await service.seriesPosition(tmdbId: t.tmdbId), editingReview?.id == draft.id,
                       editingReview?.seriesIndex == nil {
                        draft.seriesIndex = pos.index
                        editingReview = draft
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveReview(_ r: Review) {
        do {
            try service?.saveReview(r, markEdited: true)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteReview(_ r: Review) {
        do {
            try service?.deleteReview(r)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendReview(_ r: Review, overwrite: Bool) async throws -> (url: URL, review: Review) {
        guard let service else { throw ReviewError.noVault }
        defer { reload() }
        let result = try await service.sendReview(r, overwrite: overwrite)
        reviewStates[r.id] = .inSync
        return result
    }

    /// finds the note by its watchlist_id and opens it; returns the review with its current path and title
    func openInObsidian(_ r: Review) throws -> Review {
        guard let service else { throw ReviewError.noVault }
        let result = try service.openURL(for: r)
        NSWorkspace.shared.open(result.url)
        reload()
        return result.review
    }

    func relinkNote(_ r: Review, file: URL) throws -> Review {
        guard let service else { throw ReviewError.noVault }
        let updated = try service.relinkNote(r, file: file)
        reviewStates[r.id] = .inSync
        reload()
        return updated
    }

    func setAllAvailable(_ t: Title, _ on: Bool) {
        do {
            try service?.setAllAvailable(t, on)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setMovieWatched(_ t: Title, on day: String?) {
        do {
            try service?.setMovieWatched(t, on: day)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func externalRatings(_ r: Review) async -> ExternalRatings? {
        guard r.mediaType == .movie, let service else { return nil }
        return try? await service.externalRatings(tmdbId: r.tmdbId).ratings
    }

    var hasOMDbKey: Bool { APIKeyStore.resolve(paths, name: APIKeyStore.omdbVariableName) != nil }

    func saveOMDbKey(_ key: String) {
        do {
            try APIKeyStore.save(key, paths, name: APIKeyStore.omdbVariableName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // settings

    func saveKey(_ key: String) {
        do {
            try APIKeyStore.save(key, paths)
            open()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveConfig(_ new: AppConfig) {
        do {
            try ConfigStore.save(new, paths)
            config = new
            service?.config = new
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
