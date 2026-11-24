import AppKit
import Foundation
import Observation
import SwiftUI
import WatchlistCore

// sidebar

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case whatsNew, unwatched, library, reviews, insights, chat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whatsNew: return "What's New"
        case .unwatched: return "To Watch"
        case .library: return "Library"
        case .reviews: return "Reviews"
        case .insights: return "Insights"
        case .chat: return "Ask Claude"
        }
    }

    var symbol: String {
        switch self {
        case .whatsNew: return "calendar"
        case .unwatched: return "play.circle"
        case .library: return "books.vertical"
        case .reviews: return "star.bubble"
        case .insights: return "chart.dots.scatter"
        case .chat: return "bubble.left.and.text.bubble.right"
        }
    }
}

// library

enum LibraryType: String, CaseIterable, Identifiable {
    case all = "All", movies = "Movies", tv = "TV"
    var id: String { rawValue }
}

enum LibraryStatus: String, CaseIterable, Identifiable {
    case toWatch = "To Watch", waiting = "Waiting", watched = "Watched", stopped = "Stopped", all = "All"
    var id: String { rawValue }
    /// the library's status filter. to watch has its own sidebar item, so it is not repeated here
    static let filters: [LibraryStatus] = [.all, .waiting, .watched, .stopped]
}

/// one row in the library: a watchlist title, or a title known only from your reviews
struct LibraryEntry: Identifiable, Hashable {
    var id: String
    var tmdbId: Int
    var mediaType: MediaType
    var name: String
    var status: LibraryStatus
    /// on the watchlist, so it has a full detail view
    var onWatchlist: Bool
    var finishedOn: String?
    var stoppedOn: String?
    var reviews: [Review]
    /// set for a vault note that is not linked to a tmdb title yet
    var note: ImportCandidate? = nil

    /// the latest rating, for the row
    var rating: Double? { note?.rating ?? reviews.max { ($0.finishedOn ?? "") < ($1.finishedOn ?? "") }?.rating }
}

// model

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let periodicInterval: TimeInterval = 6 * 3600

    var service: WatchlistService?
    let updates = Updates()
    /// icloud sync with the iphone app; nil in builds without the icloud entitlement
    var cloud: CloudSync?
    var syncStatus = CloudSync.Status()
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
    var calendarEvents: [CalendarEvent] = []
    /// vault notes without a watchlist_id, shown in the library so nothing is hidden from search
    var unlinkedNotes: [ImportCandidate] = []
    var calendarLoading = false
    var libraryType: LibraryType = .all
    /// type filter for the to watch list
    var toWatchType: LibraryType = .all
    var libraryStatus: LibraryStatus = .all
    var librarySearch = ""
    /// posters and details for history titles, filled lazily as rows appear
    var summaries: [String: TitleSummary] = [:]
    private var summaryRequests = Set<String>()
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
            startSync(s)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // icloud sync

    private func startSync(_ s: WatchlistService) {
        guard cloud == nil, CloudSync.isAvailable else { return }
        let sync = CloudSync(db: s.db, paths: s.paths, today: { DateText.day(Date()) })
        sync.onStatus = { status in
            Task { @MainActor in AppModel.shared.syncStatus = status }
        }
        sync.onTMDBKey = { _ in
            Task { @MainActor in AppModel.shared.open() }
        }
        sync.onRemoteChange = { added in
            Task { @MainActor in await AppModel.shared.applyRemoteChanges(added) }
        }
        cloud = sync
        sync.start()
        // changes made by the screenbook cli only show up in the database, so look for them each minute.
        // pushes from icloud normally bring other devices' changes; a fetch every five minutes is the fallback.
        Task { @MainActor [weak self] in
            var minute = 0
            while let self, let cloud = self.cloud {
                try? await Task.sleep(for: .seconds(60))
                minute += 1
                cloud.pushLocalChanges()
                if minute % 5 == 0 { await cloud.fetchNow() }
            }
        }
    }

    /// another device changed something: redraw, and fetch details for titles added there
    func applyRemoteChanges(_ added: [Title]) async {
        reload()
        guard let service, service.client != nil, !added.isEmpty else { return }
        for t in added {
            _ = try? await service.refresh(t)
        }
        reload()
    }

    func syncNow() {
        guard let cloud else { return }
        Task { await cloud.syncNow() }
    }

    func reload() {
        defer { cloud?.pushLocalChanges() }
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
            libraryEntries = buildLibrary()
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
        switch item {
        case .whatsNew, .reviews, .insights, .library, .chat:
            _ = day
            return []
        case .unwatched:
            // everything you can watch now, the same as library's to watch: shows with unwatched episodes
            // and released movies you have not seen. shows with the most unwatched first, then movies by title.
            return tracked.filter { !isFinished($0) && canWatchNow($0) }.sorted { a, b in
                let ua = unwatched[a.id] ?? 0, ub = unwatched[b.id] ?? 0
                if (a.mediaType == .tv) != (b.mediaType == .tv) { return a.mediaType == .tv }
                return ua == ub ? a.title.localizedStandardCompare(b.title) == .orderedAscending : ua > ub
            }
        }
    }

    /// watchlist titles plus everything you have reviewed, rebuilt when the data changes
    private(set) var libraryEntries: [LibraryEntry] = []

    private func buildLibrary() -> [LibraryEntry] {
        var byId: [String: LibraryEntry] = [:]
        var reviewsById: [String: [Review]] = [:]
        for r in reviews where r.isSent || r.localEdits {
            reviewsById["\(r.mediaType.rawValue)-\(r.tmdbId)", default: []].append(r)
        }
        for t in titles {
            let status: LibraryStatus = t.isStopped ? .stopped : (isFinished(t) ? .watched : (canWatchNow(t) ? .toWatch : .waiting))
            byId[t.id] = LibraryEntry(id: t.id, tmdbId: t.tmdbId, mediaType: t.mediaType, name: t.title, status: status,
                                      onWatchlist: true, finishedOn: isFinished(t) ? finishedDate(t) : nil,
                                      stoppedOn: t.stoppedOn, reviews: reviewsById[t.id] ?? [])
        }
        for c in unlinkedNotes {
            let id = "note-\(c.relativePath)"
            byId[id] = LibraryEntry(id: id, tmdbId: 0, mediaType: c.mediaType, name: c.noteName, status: .watched,
                                    onWatchlist: false, finishedOn: c.finishedOn, stoppedOn: nil, reviews: [], note: c)
        }
        for (id, rs) in reviewsById where byId[id] == nil {
            let first = rs.min { $0.season < $1.season }!
            let name = first.mediaType == .tv ? NoteImport.splitSeason(first.noteTitle).show : first.noteTitle
            byId[id] = LibraryEntry(id: id, tmdbId: first.tmdbId, mediaType: first.mediaType, name: name, status: .watched,
                                    onWatchlist: false, finishedOn: rs.compactMap(\.finishedOn).max(), stoppedOn: nil, reviews: rs)
        }
        return Array(byId.values)
    }

    /// library entries after the type, status, and search filters, in a sensible order for the status
    func filteredLibrary(type: LibraryType? = nil, status: LibraryStatus? = nil, search: String? = nil) -> [LibraryEntry] {
        let type = type ?? libraryType
        let status = status ?? libraryStatus
        let q = (search ?? librarySearch).trimmingCharacters(in: .whitespaces)
        // a search looks across every status, so a title is found wherever it lives
        let entries = libraryEntries.filter { e in
            (type == .all || (type == .movies) == (e.mediaType == .movie))
                && (!q.isEmpty || status == .all || e.status == status)
                && (q.isEmpty || e.name.localizedCaseInsensitiveContains(q)
                    || e.reviews.contains { $0.noteTitle.localizedCaseInsensitiveContains(q) })
        }
        if !q.isEmpty {
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        switch status {
        case .waiting:
            // soonest next date first
            let day = today
            func next(_ e: LibraryEntry) -> String { title(e.id)?.nextDate(today: day) ?? "9999" }
            return entries.sorted { (next($0), $0.name) < (next($1), $1.name) }
        case .watched:
            return entries.sorted { ($0.finishedOn ?? "", $1.name) > ($1.finishedOn ?? "", $0.name) }
        case .stopped:
            return entries.sorted { ($0.stoppedOn ?? "") > ($1.stoppedOn ?? "") }
        default:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func libraryEntry(_ id: String?) -> LibraryEntry? {
        guard let id else { return nil }
        return libraryEntries.first { $0.id == id }
    }

    /// rescans the vault for notes without a watchlist_id, off the main thread
    func loadUnlinkedNotes() async {
        guard let service, ObsidianVault.resolve(config) != nil else { return }
        if let notes = try? await Task.detached(operation: { try service.unlinkedNotes() }).value {
            unlinkedNotes = notes
            libraryEntries = buildLibrary()
        }
    }

    /// links a vault note to a tmdb title and selects it in the library
    func linkNote(_ c: ImportCandidate, to result: SearchResult, renameTo: String?) async -> Bool {
        guard let service else { return false }
        do {
            let id = try await service.linkNote(c, to: result, renameTo: renameTo)
            reload()
            await loadUnlinkedNotes()
            if let (type, tmdb, _) = NoteImport.parseId(id) { selectedTitleID = "\(type.rawValue)-\(tmdb)" }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// the next 30 days of episodes and releases for the calendar
    func loadCalendar() async {
        guard let service, hasKey, !calendarLoading else { return }
        calendarLoading = true
        defer { calendarLoading = false }
        if let events = try? await service.calendarEvents(days: 30) { calendarEvents = events }
        calendarLoading = false
        if let path = UserDefaults.standard.string(forKey: "renderCalendarTo") {
            renderImage(CalendarContent(), to: path)
        }
    }

    /// debug: writes a view to light and dark images for layout checks
    func renderImage<V: View>(_ content: V, to path: String) {
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = content
                .environment(self)
                .frame(width: 1100)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
            }
        }
        NSApp.appearance = nil
    }

    /// fetches a history title's poster and details once
    func loadSummary(_ e: LibraryEntry) {
        guard summaries[e.id] == nil, !summaryRequests.contains(e.id), let service else { return }
        summaryRequests.insert(e.id)
        Task {
            if let s = try? await service.summary(e.mediaType, e.tmdbId) { summaries[e.id] = s }
        }
    }

    func addFromHistory(_ e: LibraryEntry) async {
        guard let service else { return }
        do {
            try await service.addFromHistory(e.mediaType, e.tmdbId)
            reload()
            selectedTitleID = e.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// watched movies, and shows that have ended with nothing left to watch
    func isFinished(_ t: Title) -> Bool {
        switch t.mediaType {
        case .movie:
            return t.watchedOn != nil
        case .tv:
            // a miniseries is done once you have seen it all, even if tmdb still lists it as airing
            let ended = ["Ended", "Canceled", "Cancelled"].contains(t.status ?? "")
                || t.seriesType?.caseInsensitiveCompare("Miniseries") == .orderedSame
            return ended && (unwatched[t.id] ?? 0) == 0 && !(watchedByTitle[t.id] ?? []).isEmpty
        }
    }

    /// something is available to watch today: unwatched aired episodes, or a released movie you have not seen
    func canWatchNow(_ t: Title) -> Bool {
        switch t.mediaType {
        case .tv:
            return (unwatched[t.id] ?? 0) > 0
        case .movie:
            let day = today
            let released = [t.regionReleaseDate, t.digitalReleaseDate].compactMap { $0 }.contains { $0 <= day }
            return t.watchedOn == nil && released
        }
    }

    private func finishedDate(_ t: Title) -> String {
        t.watchedOn ?? t.lastAiredDate ?? ""
    }

    func count(for item: SidebarItem) -> Int? {
        switch item {
        case .whatsNew:
            guard let report else { return nil }
            let n = report.releasedMovies.count + report.newEpisodeShows.count + report.newlyStreaming.count
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
            Task { @MainActor in
                await self?.syncReviews()
                if let cloud = self?.cloud { await cloud.fetchNow() }
            }
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
            selection = .library
            libraryStatus = .all
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
            await loadCalendar()
            if config.notifyNewEpisodes {
                await Notifier.post(r.newEpisodeShows)
            }
            if config.notifyMovieReleases {
                await Notifier.postReleases(r.releasedMovies, region: r.region)
            }
            if config.notifyStreaming {
                await Notifier.postStreaming(r.newlyStreaming)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func search(_ text: String) async throws -> [SearchResult] {
        guard let service else { return [] }
        return try await service.search(text)
    }

    /// switches the sidebar section. the open title stays only if the new list shows it; what's new
    /// always goes back to the calendar.
    func selectSection(_ item: SidebarItem) {
        selection = item
        guard let id = selectedTitleID else { return }
        let stillListed: Bool
        switch item {
        case .unwatched: stillListed = items(for: .unwatched).contains { $0.id == id }
        case .library: stillListed = filteredLibrary().contains { $0.id == id }
        default: stillListed = false
        }
        if !stillListed { selectedTitleID = nil }
    }

    /// selects a title, switching views if it does not belong in the current list
    func showInList(_ t: Title) {
        let visibleHere: Bool
        switch selection {
        case .unwatched: visibleHere = items(for: .unwatched).contains { $0.id == t.id }
        case .library:
            let e = libraryEntries.first { $0.id == t.id }
            visibleHere = libraryStatus == .all || e?.status == libraryStatus
        default: visibleHere = false
        }
        if !visibleHere {
            selection = .library
            let status = libraryEntries.first { $0.id == t.id }?.status ?? .all
            libraryStatus = LibraryStatus.filters.contains(status) ? status : .all
            librarySearch = ""
        }
        selectedTitleID = t.id
    }

    func add(_ result: SearchResult, caughtUp: Bool) async -> Bool {
        guard let service else { return false }
        do {
            let t = try await service.add(result, caughtUp: caughtUp)
            reload()
            showInList(t)
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

    /// streaming services in your region, for the settings picker
    func streamingServices() async -> [Provider] {
        guard let service else { return [] }
        do { return try await service.streamingServices() } catch {
            errorMessage = error.localizedDescription
            return []
        }
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
            await loadUnlinkedNotes()
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

    var hasClaudeKey: Bool { APIKeyStore.resolve(paths, name: Claude.keyName) != nil }

    func saveClaudeKey(_ key: String) {
        do {
            try APIKeyStore.save(key, paths, name: Claude.keyName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// a title's name from the watchlist or review history, for chat activity lines
    func titleName(_ tmdbId: Int, _ type: MediaType) -> String? {
        titles.first { $0.tmdbId == tmdbId && $0.mediaType == type }?.title
            ?? libraryEntries.first { $0.tmdbId == tmdbId && $0.mediaType == type }?.name
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
            cloud?.pushTMDBKey()
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
