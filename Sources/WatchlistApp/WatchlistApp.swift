import AppKit
import SwiftUI
import UserNotifications
import WatchlistCore

// app

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // running from swift run has no bundle, so make sure we show up as a regular app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        WindowTweaks.install()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        // silent pushes from icloud tell the sync engine another device changed something
        if CloudSync.isAvailable { NSApp.registerForRemoteNotifications() }
    }

    /// show banners even while the app is in front
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// clicking a notification opens that show
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[Notifier.titleKey] as? String
        Task { @MainActor in
            AppModel.shared.openTitle(id)
            completionHandler()
        }
    }

    /// with the menu bar item on, closing the window keeps the app running so the badge stays
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ConfigStore.load(.standard()).showInMenuBar
    }
}

@main
struct WatchlistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Screenbook", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") { model.updates.check() }
                    .disabled(!model.updates.available)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Title...") { model.showingAdd = true }
                    .keyboardShortcut("n")
                    .disabled(!model.hasKey)
            }
            CommandMenu("Tools") {
                Button("Check Now") { Task { await model.check() } }
                    .keyboardShortcut("r")
                    .disabled(!model.hasKey || model.isChecking)
                Button("Force Refresh All") { Task { await model.check(force: true) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.hasKey || model.isChecking)
                Divider()
                Button("Write Digest") { Task { await model.writeDigest() } }
                    .keyboardShortcut("d")
                    .disabled(!model.hasKey)
                Button("Export CSV") { model.exportCSV() }
                Button("Import Reviews from Obsidian...") { model.showingImport = true }
                    .disabled(!model.hasKey)
                Button("Sync Reviews from Obsidian") { Task { await model.syncReviews(force: true) } }
                Button("Fill IMDb and Rotten Tomatoes...") { model.showingFillRatings = true }
                    .disabled(!model.hasKey)
                Divider()
                Button("Show Data Folder") { model.revealDataFolder() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.config.showInMenuBar },
            set: { value in
                var c = model.config
                c.showInMenuBar = value
                model.saveConfig(c)
            }
        )) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(count: model.totalUnwatched)
        }
    }
}

// menu bar

struct MenuBarLabel: View {
    let count: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "play.tv.fill" : "play.tv")
            if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
        .help(count > 0 ? "\(count) unwatched episodes" : "Screenbook")
        .onAppear { AppModel.shared.openWindowAction = openWindow }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shows = model.unwatchedShows
        if shows.isEmpty {
            Text("All caught up")
        } else {
            Text("\(model.totalUnwatched) unwatched episodes")
            ForEach(shows.prefix(15), id: \.title.id) { item in
                Button("\(item.title.title)  (\(item.count))") {
                    show(item.title)
                }
            }
            if shows.count > 15 {
                Text("and \(shows.count - 15) more")
            }
        }
        Divider()
        if let r = model.report {
            Text("Last checked \(r.checkedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        Button(model.isChecking ? "Checking..." : "Check Now") {
            Task { await model.check() }
        }
        .disabled(!model.hasKey || model.isChecking)
        Button("Open Screenbook") { openMain() }
        Divider()
        Button("Quit Screenbook") { NSApp.terminate(nil) }
    }

    private func show(_ t: Title) {
        model.selection = .unwatched
        model.selectedTitleID = t.id
        openMain()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
