import AgentiloCore
import AppKit

/// Starts a shell command in a new terminal window, for "Open in terminal".
@MainActor
enum TerminalLauncher {
    /// False when the terminal is not installed or refused (Automation permission denied).
    @discardableResult
    static func open(_ command: String, in app: TerminalApp) -> Bool {
        switch app {
        case .none:
            return false
        case .ghostty:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppState.ghosttyBundleID) else { return false }
            // A login shell, so PATH and aliases match the user's own windows.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["-e", shell, "-lic", command]
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        case .iterm:
            return run("""
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escaped(command))"
            end tell
            """)
        case .terminal:
            return run("""
            tell application "Terminal"
                activate
                do script "\(escaped(command))"
            end tell
            """)
        }
    }

    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Inside an AppleScript string literal.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
