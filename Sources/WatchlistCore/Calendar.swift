import Foundation

// release calendar

/// one thing landing on a day: a tv episode, or a movie release
public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public var titleId: String
    public var tmdbId: Int
    public var mediaType: MediaType
    public var title: String
    /// yyyy-MM-dd
    public var date: String
    /// "S03E04", "In theaters", or "Digital"
    public var label: String
    public var episodeName: String?

    public var id: String { "\(titleId)-\(date)-\(label)" }

    public init(titleId: String, tmdbId: Int, mediaType: MediaType, title: String, date: String, label: String, episodeName: String? = nil) {
        self.titleId = titleId
        self.tmdbId = tmdbId
        self.mediaType = mediaType
        self.title = title
        self.date = date
        self.label = label
        self.episodeName = episodeName
    }
}

extension WatchlistService {
    /// everything landing between today and `days` from now for tracked titles. tv episodes come from the
    /// season episode list so every episode in the window shows, not only the next one.
    public func calendarEvents(days: Int = 30) async throws -> [CalendarEvent] {
        let start = today
        let end = DateText.addDays(start, days)
        func inWindow(_ d: String?) -> Bool { d.map { $0 >= start && $0 <= end } ?? false }
        var events: [CalendarEvent] = []

        for t in try titles() where !t.isStopped {
            switch t.mediaType {
            case .movie:
                guard t.watchedOn == nil else { continue }
                if inWindow(t.regionReleaseDate) {
                    events.append(CalendarEvent(titleId: t.id, tmdbId: t.tmdbId, mediaType: .movie, title: t.title,
                                                date: t.regionReleaseDate!, label: "In theaters"))
                }
                if inWindow(t.digitalReleaseDate), t.digitalReleaseDate != t.regionReleaseDate {
                    events.append(CalendarEvent(titleId: t.id, tmdbId: t.tmdbId, mediaType: .movie, title: t.title,
                                                date: t.digitalReleaseDate!, label: "Digital"))
                }
            case .tv:
                guard !t.allAvailable, let next = t.nextAir, inWindow(t.nextAirDate) else { continue }
                var found: [CalendarEvent] = []
                // read the season (and the following one, in case a new season starts in the window)
                for season in [next.season, next.season + 1] {
                    guard let client, let eps = try? await client.season(t.tmdbId, season).episodes else { continue }
                    for ep in eps {
                        guard let d = DateText.normalize(ep.airDate), inWindow(d) else { continue }
                        found.append(CalendarEvent(titleId: t.id, tmdbId: t.tmdbId, mediaType: .tv, title: t.title,
                                                   date: d, label: ep.ref.code, episodeName: ep.name))
                    }
                }
                if found.isEmpty, let d = t.nextAirDate {
                    found.append(CalendarEvent(titleId: t.id, tmdbId: t.tmdbId, mediaType: .tv, title: t.title,
                                               date: d, label: next.code))
                }
                events += found
            }
        }
        return events.sorted { ($0.date, $0.title, $0.label) < ($1.date, $1.title, $1.label) }
    }
}
