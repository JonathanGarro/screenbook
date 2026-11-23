import Foundation
import Observation
import Sparkle

// updates through sparkle. it reads the appcast attached to the latest github release, downloads a
// newer dmg, checks it against the release signing key, and installs it. it sends nothing about the
// mac or the library. a build without a version in its Info.plist (swift run) never checks.
@MainActor
@Observable
final class Updates {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    var automaticChecks = false
    var automaticInstalls = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    init() {
        guard current != nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        automaticInstalls = controller.updater.automaticallyDownloadsUpdates
    }

    var available: Bool { controller != nil }

    /// sparkle's own window, saying it's up to date or offering the update
    func check() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        automaticChecks = on
    }

    func setAutomaticInstalls(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
        automaticInstalls = on
    }
}
