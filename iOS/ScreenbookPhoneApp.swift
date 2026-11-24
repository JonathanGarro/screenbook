import SwiftUI
import UIKit
import WatchlistCore

// the iphone companion: what's new, to watch, the library, and adding titles. reviews stay on the mac.

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // silent pushes from icloud tell the sync engine the mac changed something
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct ScreenbookPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase
    @State private var model = PhoneModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, now in
            if now == .active { Task { await model.becameActive() } }
        }
    }
}

// theme

enum Theme {
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x8a / 255, green: 0x84 / 255, blue: 0xff / 255, alpha: 1)
            : UIColor(red: 0x4b / 255, green: 0x44 / 255, blue: 0xc8 / 255, alpha: 1)
    })
}

// root

struct RootView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        TabView {
            Tab("What's New", systemImage: "sparkles") { WhatsNewView() }
                .badge(model.newEpisodes.count)
            Tab("To Watch", systemImage: "play.rectangle") { NavigationStack { ToWatchView() } }
            Tab("Library", systemImage: "books.vertical") { NavigationStack { LibraryView() } }
            Tab(role: .search) { NavigationStack { AddView() } }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
