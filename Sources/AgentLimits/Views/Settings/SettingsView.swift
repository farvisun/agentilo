import AgentLimitsCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsTab(state: state)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            ProxyTab(state: state)
                .tabItem { Label("Proxy", systemImage: "network") }
        }
        .padding(16)
        .frame(width: 640, height: 480)
    }
}

struct GeneralTab: View {
    @Bindable var state: AppState
    @State private var loginError: String?

    private let intervals: [(String, Double)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600),
    ]

    var body: some View {
        Form {
            Picker("Check limits every", selection: $state.settings.refreshInterval) {
                ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
            }
            Picker("Show percentage as", selection: $state.settings.displayMode) {
                ForEach(UsageDisplay.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Expand notch on", selection: $state.settings.expandTrigger) {
                ForEach(ExpandTrigger.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Collapsed notch shows", selection: $state.settings.pillMode) {
                ForEach(PillMode.allCases) { Text($0.displayName).tag($0) }
            }
            if state.settings.pillMode == .pinned {
                Picker("Pinned account", selection: $state.settings.pinnedAccount) {
                    Text("None").tag(UUID?.none)
                    ForEach(state.limitAccounts) { acct in
                        Text("\(acct.provider.displayName) · \(acct.label)").tag(UUID?.some(acct.id))
                    }
                }
            }
            Picker("Collapsed limit", selection: $state.settings.pillWindow) {
                ForEach(PillWindow.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Collapsed usage as", selection: $state.settings.pillStyle) {
                ForEach(PillStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show local token statistics", isOn: $state.settings.showTokenStats)
            Toggle("Launch at login", isOn: Binding(
                get: { state.settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Section {
                Text("Usage comes straight from each provider's server using the sign-in the agent already saved on this Mac. Tokens are read-only and only sent to their own provider.\n\nWhen a server is unreachable or rate limited: Codex limits are read from its own session logs (exact as of the last Codex turn); Claude limits are estimated from the last server response plus tokens logged since, marked ≈.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            state.settings.launchAtLogin = on
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
    }
}

struct AccountsTab: View {
    @Bindable var state: AppState
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each agent home is one account. Limits are fetched per home; token statistics add up all enabled homes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($state.settings.accounts) { $acct in
                    AccountRow(account: $acct, status: state.status(acct))
                        .tag(acct.id)
                }
                .onMove { state.settings.accounts.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Menu {
                    ForEach(Provider.allCases) { p in
                        Button("\(p.displayName) home…") { addAccount(p) }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()
                Button {
                    state.settings.accounts.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                Button("Detect homes") {
                    state.settings.accounts += AccountDetector.detect(existing: state.settings.accounts)
                }
                Spacer()
                Button("Refresh all") { state.refreshAll(force: true) }
            }
        }
    }

    private func addAccount(_ provider: Provider) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(provider.displayName) home directory"
        switch provider {
        case .claude: panel.directoryURL = URL(fileURLWithPath: Paths.home)
        case .codex: panel.directoryURL = URL(fileURLWithPath: Paths.home)
        case .cursor: panel.directoryURL = URL(fileURLWithPath: CursorCredentials.defaultHome)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = Paths.abbreviate(url.path)
        state.settings.accounts.append(Account(
            provider: provider, homePath: path, label: AccountDetector.defaultLabel(provider, url.path)
        ))
    }
}

struct AccountRow: View {
    @Binding var account: Account
    var status: AccountStatus

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $account.enabled).labelsHidden()
            ProviderIcon(provider: account.provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Label", text: $account.label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                Text(Paths.abbreviate(account.homePath))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusText
            Toggle("Limits", isOn: $account.trackLimits)
                .toggleStyle(.checkbox)
                .help("Fetch plan limits from the provider. Off = only count tokens from this home.")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusText: some View {
        if status.loading {
            ProgressView().controlSize(.small)
        } else if let err = status.error {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(err)
        } else if let w = status.snapshot?.primary {
            Text("\(w.title) \(Int(w.usedPercent.rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
