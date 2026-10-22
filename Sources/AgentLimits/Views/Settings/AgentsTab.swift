import AgentLimitsCore
import SwiftUI

/// Everything agents and scripts use to talk to the app: local API and command-line tool.
struct AgentsTab: View {
    @Bindable var state: AppState
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var cliError: String?

    var body: some View {
        Form {
            Section("Local API") {
                Toggle("Serve limits on 127.0.0.1", isOn: $state.settings.apiEnabled)
                TextField("Port", value: $state.settings.apiPort, format: .number.grouping(.never))
                    .disabled(!state.settings.apiEnabled)
                Toggle("Include account labels (emails) in output", isOn: $state.settings.apiIncludeLabels)
                    .disabled(!state.settings.apiEnabled)
                if let err = state.serverError {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else if state.settings.apiEnabled {
                    Text("GET http://127.0.0.1:\(String(state.settings.apiPort))/v1/limits — loopback only, refuses browser pages, never serves credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Command line") {
                HStack {
                    Text(cliInstalled ? "Installed at \(Paths.abbreviate(CLIInstaller.linkPath))" : "agentlimits is not installed")
                    Spacer()
                    if cliInstalled {
                        Button("Remove") { act(CLIInstaller.uninstall) }
                    } else {
                        Button("Install") { act(CLIInstaller.install) }
                            .disabled(CLIInstaller.executablePath == nil)
                    }
                }
                if let cliError {
                    Text(cliError).font(.caption).foregroundStyle(.red)
                }
                Text("`agentlimits limits --short` prints one line for a status bar. In a Claude Code status line command: `agentlimits limits --short`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            cliError = nil
        } catch {
            cliError = error.localizedDescription
        }
        cliInstalled = CLIInstaller.isInstalled
    }
}

/// Symlinks the app's binary as `~/.local/bin/agentlimits`.
enum CLIInstaller {
    static var linkPath: String { Paths.home + "/.local/bin/agentlimits" }

    /// The bundled binary; nil when running from `swift run`, where a link would go stale.
    static var executablePath: String? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return Bundle.main.executablePath
    }

    static var isInstalled: Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else { return false }
        return dest == executablePath
    }

    static func install() throws {
        guard let exe = executablePath else { return }
        let fm = FileManager.default
        try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Replace only our own link (or a stale one), never a real file someone put there.
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try fm.removeItem(atPath: linkPath) }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exe)
    }

    static func uninstall() throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return }
        try FileManager.default.removeItem(atPath: linkPath)
    }
}
