import AgentiloCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var notch: NotchWindowController!
    private var settingsWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        notch = NotchWindowController(state: state) { [weak self] in self?.openSettings() }
        notch.show()
        state.start()
        if state.settings.accounts.isEmpty { openSettings() }
        // Debug: `--preview-alert` drops a sample alert for screenshots.
        if CommandLine.arguments.contains("--preview-alert") {
            Task { @MainActor [state] in
                try? await Task.sleep(for: .seconds(2))
                state?.postTestAlert()
            }
        }
        // Debug: `--preview-expanded` opens the notch on the first account with a switch suggestion.
        if CommandLine.arguments.contains("--preview-expanded") {
            Task { @MainActor [state] in
                try? await Task.sleep(for: .seconds(6))
                guard let state else { return }
                let pages = state.pages
                state.page = pages.firstIndex {
                    if case .account(let a) = $0 { state.suggestion(from: a) != nil } else { false }
                } ?? 0
                state.expanded = true
            }
        }
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
}
