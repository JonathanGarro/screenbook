import AppKit
import Foundation
import UserNotifications
import WatchlistCore

// notifications

/// posts macos notifications for new episodes and movie releases. needs a real app bundle, so it is a no-op under swift run.
@MainActor
enum Notifier {
    nonisolated static let titleKey = "titleID"
    /// above this many shows, one summary notification is posted instead of one per show
    static let maxIndividual = 4

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func status() async -> UNAuthorizationStatus {
        guard available else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(_ updates: [ShowUpdate]) async {
        guard available, !updates.isEmpty, await requestAuthorization() else { return }
        if updates.count > maxIndividual {
            let total = updates.reduce(0) { $0 + $1.newlyAired.count }
            let names = updates.prefix(3).map(\.title.title).joined(separator: ", ")
            await send(id: "summary-\(Date().timeIntervalSince1970)",
                       title: "\(total) new episodes",
                       body: "\(names), and \(updates.count - 3) more shows",
                       titleID: nil)
            return
        }
        for u in updates {
            await send(id: "\(u.title.id)-\(u.newlyAired.last?.code ?? "")",
                       title: u.title.title,
                       body: describe(u.newlyAired),
                       titleID: u.title.id)
        }
    }

    /// one notification per newly released movie, or a summary when there are many
    static func postReleases(_ movies: [Title], region: String) async {
        guard available, !movies.isEmpty, await requestAuthorization() else { return }
        if movies.count > maxIndividual {
            let names = movies.prefix(3).map(\.title).joined(separator: ", ")
            await send(id: "releases-\(Date().timeIntervalSince1970)",
                       title: "\(movies.count) movies released",
                       body: "\(names), and \(movies.count - 3) more",
                       titleID: nil)
            return
        }
        for m in movies {
            var body = "Released \(DateText.pretty(m.regionReleaseDate)) (\(region))"
            if let digital = m.digitalReleaseDate, digital > DateText.day(Date()) {
                body += ". Digital \(DateText.pretty(digital))"
            }
            await send(id: "\(m.id)-released", title: m.title, body: body, titleID: m.id)
        }
    }

    static func describe(_ eps: [EpisodeRef]) -> String {
        switch eps.count {
        case 0: return "New episode"
        case 1: return "New episode \(eps[0].code)"
        default: return "\(eps.count) new episodes, \(eps.first!.code) to \(eps.last!.code)"
        }
    }

    static func sendTest() async {
        guard available, await requestAuthorization() else { return }
        await send(id: "test-\(Date().timeIntervalSince1970)", title: "Watchlist",
                   body: "Notifications are working. You will hear about new episodes and movie releases.", titleID: nil)
    }

    private static func send(id: String, title: String, body: String, titleID: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "new-episodes"
        if let titleID { content.userInfo = [titleKey: titleID] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
