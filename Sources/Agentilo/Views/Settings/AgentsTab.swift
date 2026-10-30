import AgentiloCore
import SwiftUI

/// Everything agents and scripts use to talk to the app: local API and command-line tool.
struct AgentsTab: View {
    @Bindable var state: AppState
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var cliError: String?
    @State private var hookRevision = 0

    var body: some View {
        Form {
            Section("Agent activity") {
                Toggle("Read agent state from herdr", isOn: $state.settings.herdrEnabled)
                    .disabled(HerdrSource.executable == nil)
                Toggle("Alert when an agent needs input or approval", isOn: $state.settings.agentAttentionAlerts)
                Toggle("Alert when an agent finishes a longer turn", isOn: $state.settings.agentDoneAlerts)
                Toggle("Show the start of the agent's last reply", isOn: $state.settings.agentDoneSummary)
                Toggle("Show a working agent's turn time in the collapsed notch", isOn: $state.settings.pillShowsAgents)
                Text(HerdrSource.executable == nil
                     ? "herdr is not installed. Hooks below still report Claude Code, Codex and Gemini CLI sessions."
                     : "herdr reports every agent pane (working, blocked, idle); hooks add the current tool and approval details. Click an agent in the notch to jump to its pane in Ghostty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            KeepAwakeSection(state: state)

            Section("Approvals") {
                Toggle("Answer Claude Code permission prompts from the notch", isOn: $state.settings.approvalsEnabled)
                Picker("Hand back to the terminal after", selection: $state.settings.approvalTimeout) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .disabled(!state.settings.approvalsEnabled)
                Text("Claude Code waits for the notch before it shows its own prompt, so an unanswered card delays the terminal by this long. \"Terminal\" on the card or a focused herdr pane skips the card. After changing this, update the Claude hooks below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hooks") {
                let accounts = state.settings.accounts.filter { $0.enabled && $0.provider != .cursor }
                if accounts.isEmpty {
                    Text("No Claude Code, Codex or Gemini CLI homes configured.").foregroundStyle(.secondary)
                }
                ForEach(accounts) { acct in
                    HookRow(
                        account: acct, executable: CLIInstaller.executablePath,
                        approvals: state.settings.approvalsEnabled, approvalTimeout: state.settings.approvalTimeout,
                        revision: hookRevision
                    ) {
                        hookRevision += 1
                    }
                }
                if CLIInstaller.executablePath == nil {
                    Text("Run the bundled app (make run / make install) to install hooks.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Adds commands marked `# agentilo` to each home's settings.json (Claude Code, Gemini CLI) or hooks.json (Codex); other hooks stay untouched and the original file is kept as *.agentilo-bak. Install from /Applications so the path stays valid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Text(cliInstalled ? "Installed at \(Paths.abbreviate(CLIInstaller.linkPath))" : "agentilo is not installed")
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
                Text("`agentilo limits --short` prints one line for a status bar. In a Claude Code status line command: `agentilo limits --short`.")
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

private struct HookRow: View {
    var account: Account
    var executable: String?
    var approvals: Bool
    var approvalTimeout: Int
    /// Bumped after a change so the status is read again.
    var revision: Int
    var changed: () -> Void
    @State private var error: String?

    var body: some View {
        let status = executable.map { HookInstaller.status(
            for: account, executable: $0, approvals: approvals, approvalTimeout: approvalTimeout
        ) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProviderIcon(provider: account.provider, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).lineLimit(1)
                    Text(statusText(status)).font(.caption).foregroundStyle(statusColor(status))
                }
                Spacer()
                if let executable {
                    if status != .notInstalled {
                        Button("Remove") { act { try HookInstaller.uninstall(for: account) } }
                    }
                    if status != .installed {
                        Button(status == .outdated ? "Update" : "Install") {
                            act {
                                try HookInstaller.install(
                                    for: account, executable: executable, approvals: approvals, approvalTimeout: approvalTimeout
                                )
                            }
                        }
                    }
                }
            }
            if account.provider == .codex, !HookInstaller.codexHooksEnabled(home: account.homeURL) {
                Text("Codex runs hooks only with `hooks = true` under [features] in config.toml.")
                    .font(.caption).foregroundStyle(.orange)
            } else if account.provider == .codex, status == .installed {
                Text("Codex asks you to trust new hooks the next time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if account.provider == .gemini, !HookInstaller.geminiHooksEnabled(home: account.homeURL) {
                Text("Gemini CLI has hooks turned off (`hooksConfig.enabled` in settings.json).")
                    .font(.caption).foregroundStyle(.orange)
            } else if account.provider == .gemini, status == .installed {
                Text("Gemini CLI runs hooks only in folders you trust; approvals stay in the terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        changed()
    }

    private func statusText(_ s: HookInstaller.Status?) -> String {
        switch s {
        case nil: "—"
        case .installed: "Hooks installed"
        case .notInstalled: "Not installed"
        case .outdated: "Installed for another copy of the app, or incomplete"
        case .unsupported(let why): why
        }
    }

    private func statusColor(_ s: HookInstaller.Status?) -> Color {
        switch s {
        case .installed: .green
        case .outdated: .orange
        default: .secondary
        }
    }
}

/// Symlinks the app's binary as `~/.local/bin/agentilo`.
enum CLIInstaller {
    static var linkPath: String { Paths.home + "/.local/bin/agentilo" }
    /// Link name from before the rename; removed on install so it cannot go stale.
    static var legacyLinkPath: String { Paths.home + "/.local/bin/agentlimits" }

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
        if (try? fm.destinationOfSymbolicLink(atPath: legacyLinkPath)) != nil { try? fm.removeItem(atPath: legacyLinkPath) }
    }

    static func uninstall() throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return }
        try FileManager.default.removeItem(atPath: linkPath)
    }
}

/// Keep the Mac awake while agents work, and the root helper for the lid-closed mode.
private struct KeepAwakeSection: View {
    @Bindable var state: AppState
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section("Keep awake") {
            Toggle("Keep the Mac awake while an agent works", isOn: $state.settings.keepAwake)
            Toggle("Also with the lid closed", isOn: $state.settings.keepAwakeLidClosed)
                .disabled(!state.settings.keepAwake || !state.keepAwakeHelperInstalled)
            HStack {
                Text(helperText)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if state.keepAwakeHelperInstalled {
                    Button("Remove") { change(state.removeKeepAwakeHelper) }
                } else {
                    Button(KeepAwakeHelper.isPresent ? "Update…" : "Install…") { change(state.installKeepAwakeHelper) }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker("On battery, allow sleep below", selection: $state.settings.keepAwakeMinBattery) {
                Text("Never").tag(0)
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
            }
            .disabled(!state.settings.keepAwake)
            Text("While an agent is working (from herdr or the hooks below), idle sleep is held off, on battery too; the screen still turns off and locks. Closing the lid sleeps the Mac unless the helper is installed: a small root service that turns sleep off only while Agentilo says an agent works, and back on within 90 seconds after the last one finishes or Agentilo quits. Don't put a working Mac in a bag; it stays awake and heats up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var helperText: String {
        if state.keepAwakeHelperInstalled { return "Lid-closed helper installed" }
        return KeepAwakeHelper.isPresent ? "Lid-closed helper is out of date" : "Lid-closed helper not installed"
    }

    private func change(_ action: @escaping () async -> String?) {
        busy = true
        Task {
            let result = await action()
            error = result == "Cancelled" ? nil : result
            busy = false
        }
    }
}
