import AgentiloCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var notch: NotchWindowController!
    private var settingsWindow: NSWindow?
    private var reportsWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        notch = NotchWindowController(state: state) { [weak self] in self?.openSettings() }
        notch.show()
        state.openReports = { [weak self] in self?.openReports() }
        state.start()
        if state.settings.accounts.isEmpty { openSettings() }
        // Debug: `--preview-alert` drops a sample alert for screenshots.
        if CommandLine.arguments.contains("--preview-alert") {
            Task { @MainActor [state] in
                try? await Task.sleep(for: .seconds(2))
                state?.postTestAlert()
            }
        }
        // Debug: `--preview-reports` opens the Reports window.
        if CommandLine.arguments.contains("--preview-reports") { openReports() }
    }

    /// Never leave the Mac held awake after quitting.
    func applicationWillTerminate(_ notification: Notification) {
        state?.sleepGuard.hold(.off)
    }

    /// Reopening the app from Finder or Spotlight shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state, updater: updater)))
            w.title = "Agentilo Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openReports() {
        if reportsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ReportsView(state: state)))
            w.title = "Agentilo Reports"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 860, height: 720))
            w.center()
            reportsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        reportsWindow?.makeKeyAndOrderFront(nil)
    }
}
