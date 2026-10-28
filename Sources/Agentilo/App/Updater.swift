import AppKit
import Observation
import Sparkle

/// Sparkle, checking the appcast published with each GitHub release. Updates are verified with
/// the EdDSA key in Info.plist (`SUPublicEDKey`); the app itself is only ad-hoc signed.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    private(set) var canCheck = false
    private(set) var lastCheck: Date?

    /// False when running from `swift run`, where there is no bundle to replace.
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.isAvailable, updaterDelegate: nil, userDriverDelegate: self
        )
        refresh()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; refresh() }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        refresh()
    }

    private func refresh() {
        canCheck = Self.isAvailable && controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: SPUStandardUserDriverDelegate

    /// The app has no Dock icon, so bring it forward before Sparkle shows a window.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.refresh() }
    }
}
