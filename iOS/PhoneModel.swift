import Foundation
import Observation
import WatchlistCore

// state for the iphone app. the same database layout and service as the mac app; icloud keeps them in step.

enum PhoneStatus: String, CaseIterable, Identifiable {
    case all = "All", toWatch = "To Watch", waiting = "Waiting", watched = "Watched", stopped = "Stopped"
    var id: String { rawValue }
}

@MainActor
@Observable
final class PhoneModel {
    static let shared = PhoneModel()

    var service: WatchlistService?
    var cloud: CloudSync?
    var syncStatus = CloudSync.Status()
    var titles: [Title] = []
    var unwatched: [String: Int] = [:]
    var watched: [String: Set<EpisodeRef>] = [:]
    var hasKey = false
    var checking = false
    var lastChecked: Date?
    var errorMessage: String?

    var today: String { DateText.day(Date()) }

    init() {
        open()
    }

    func open() {
        do {
            let s = try WatchlistService.standard()
            service = s
            hasKey = s.client != nil
            lastChecked = s.lastCheck
            reload()
            startSync(s)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() {
        defer { cloud?.pushLocalChanges() }
        guard let service else { return }
        do {
            titles = try service.titles()
            var counts: [String: Int] = [:]
            var seen: [String: Set<EpisodeRef>] = [:]
            for t in titles where t.mediaType == .tv {
                counts[t.id] = t.isStopped ? 0 : try service.unwatchedAired(t).count
                seen[t.id] = try service.db.watched(tmdbId: t.tmdbId)
            }
            unwatched = counts
            watched = seen
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func title(_ id: String) -> Title? { titles.first { $0.id == id } }

    // icloud

    private func startSync(_ s: WatchlistService) {
        guard cloud == nil else { return }
        let sync = CloudSync(db: s.db, today: { DateText.day(Date()) })
        sync.onStatus = { status in
            Task { @MainActor in PhoneModel.shared.syncStatus = status }
        }
        sync.onRemoteChange = { added in
            Task { @MainActor in await PhoneModel.shared.applyRemote(added) }
        }
        cloud = sync
        sync.start()
    }

    private func applyRemote(_ added: [Title]) async {
        reload()
        guard let service, service.client != nil, !added.isEmpty else { return }
        for t in added { _ = try? await service.refresh(t) }
        reload()
    }

    /// when the app comes back to the front: pick up other devices' changes, and refresh tmdb details now and then
    func becameActive() async {
        await cloud?.fetchNow()
        if let last = lastChecked, Date().timeIntervalSince(last) < 3 * 3600 { return }
        await check()
    }

    // status, the same rules as the mac app

    func isFinished(_ t: Title) -> Bool {
        switch t.mediaType {
        case .movie:
            return t.watchedOn != nil
        case .tv:
            let ended = ["Ended", "Canceled", "Cancelled"].contains(t.status ?? "")
                || t.seriesType?.caseInsensitiveCompare("Miniseries") == .orderedSame
            return ended && (unwatched[t.id] ?? 0) == 0 && !(watched[t.id] ?? []).isEmpty
        }
    }

    func canWatchNow(_ t: Title) -> Bool {
        switch t.mediaType {
        case .tv:
            return (unwatched[t.id] ?? 0) > 0
        case .movie:
            let released = [t.regionReleaseDate, t.digitalReleaseDate].compactMap { $0 }.contains { $0 <= today }
            return t.watchedOn == nil && released
        }
    }

    func status(_ t: Title) -> PhoneStatus {
        if t.isStopped { return .stopped }
        if isFinished(t) { return .watched }
        return canWatchNow(t) ? .toWatch : .waiting
    }

    // lists

    /// shows with unwatched episodes, the most recently aired first
    var newEpisodes: [Title] {
        titles.filter { !$0.isStopped && (unwatched[$0.id] ?? 0) > 0 }
            .sorted { ($0.lastAiredDate ?? "") > ($1.lastAiredDate ?? "") }
    }

    /// next episodes and movie releases in the coming weeks
    var upcoming: [(title: Title, date: String)] {
        let limit = DateText.addDays(today, 60)
        return titles.filter { !$0.isStopped }
            .compactMap { t in t.nextDate(today: today).flatMap { $0 <= limit ? (t, $0) : nil } }
            .sorted { $0.date < $1.date }
    }

    /// shows with unwatched episodes, then released movies you have not seen
    var toWatch: [Title] {
        titles.filter { !$0.isStopped && !isFinished($0) && canWatchNow($0) }.sorted { a, b in
            if (a.mediaType == .tv) != (b.mediaType == .tv) { return a.mediaType == .tv }
            let ua = unwatched[a.id] ?? 0, ub = unwatched[b.id] ?? 0
            return ua == ub ? a.title.localizedStandardCompare(b.title) == .orderedAscending : ua > ub
        }
    }

    func library(_ status: PhoneStatus, type: MediaType?, search: String) -> [Title] {
        titles.filter { t in
            (status == .all || self.status(t) == status)
                && (type == nil || t.mediaType == type)
                && (search.isEmpty || t.title.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // actions

    func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func runAsync(_ body: () async throws -> Void) async {
        do { try await body() } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func check() async {
        guard let service, service.client != nil, !checking else { return }
        checking = true
        defer { checking = false }
        await runAsync { _ = try await service.check() }
        lastChecked = Date()
    }

    func search(_ text: String) async -> [SearchResult] {
        guard let service, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            return try await service.search(text).filter { $0.kind != nil }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func isTracked(_ r: SearchResult) -> Bool {
        guard let kind = r.kind else { return false }
        return titles.contains { $0.tmdbId == r.id && $0.mediaType == kind }
    }

    func add(_ r: SearchResult, caughtUp: Bool) async {
        guard let service else { return }
        await runAsync { _ = try await service.add(r, caughtUp: caughtUp) }
    }

    func remove(_ t: Title) {
        guard let service else { return }
        run { _ = try service.remove(t.tmdbId, t.mediaType) }
    }

    func setEpisode(_ t: Title, _ ep: EpisodeRef, watched on: Bool) {
        guard let service else { return }
        run { try service.setWatched(t.tmdbId, season: ep.season, episode: ep.episode, watched: on) }
    }

    func setSeason(_ t: Title, _ eps: [EpisodeRef], watched on: Bool) {
        guard let service else { return }
        run { try service.db.setWatched(tmdbId: t.tmdbId, eps, watched: on, on: today) }
    }

    func markUpTo(_ t: Title, _ ep: EpisodeRef) async {
        guard let service else { return }
        await runAsync { _ = try await service.markAllUpTo(t.tmdbId, season: ep.season, episode: ep.episode) }
    }

    func setMovieWatched(_ t: Title, _ on: Bool) {
        guard let service else { return }
        run { try service.setMovieWatched(t, on: on ? today : nil) }
    }

    func setStopped(_ t: Title, _ on: Bool) async {
        guard let service else { return }
        await runAsync { _ = try await service.setStopped(t.tmdbId, t.mediaType, stopped: on) }
    }

    func setAllAvailable(_ t: Title, _ on: Bool) {
        guard let service else { return }
        run { try service.setAllAvailable(t, on) }
    }

    func episodes(_ t: Title, season: Int) async -> [EpisodeDetail] {
        guard let service else { return [] }
        do { return try await service.episodes(t, season: season) } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func seasons(_ t: Title) -> [SeasonSummary] {
        (try? service?.db.seasons(tmdbId: t.tmdbId)) ?? []
    }

    func saveKey(_ key: String) async {
        guard let service else { return }
        do {
            try APIKeyStore.save(key, service.paths)
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            service.client = trimmed.isEmpty ? nil : TMDBClient(apiKey: trimmed, db: service.db)
            hasKey = service.client != nil
            if hasKey { await check() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
