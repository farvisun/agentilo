import AgentiloCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    var updater: Updater

    var body: some View {
        TabView {
            GeneralTab(state: state, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsTab(state: state)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            AlertsTab(state: state)
                .tabItem { Label("Alerts", systemImage: "bell") }
            AgentsTab(state: state)
                .tabItem { Label("Agents", systemImage: "terminal") }
            ProxyTab(state: state)
                .tabItem { Label("Proxy", systemImage: "network") }
        }
        .padding(16)
        .frame(width: 640, height: 480)
    }
}

struct GeneralTab: View {
    @Bindable var state: AppState
    @Bindable var updater: Updater
    @State private var loginError: String?

    /// 0 show, 1 blur names, 2 hide; stored as two flags so older settings keep working.
    private var captureMode: Binding<Int> {
        Binding(
            get: { state.settings.hideWhileCaptured ? 2 : state.settings.blurNamesWhileCaptured ? 1 : 0 },
            set: { mode in
                state.settings.hideWhileCaptured = mode == 2
                state.settings.blurNamesWhileCaptured = mode == 1
            }
        )
    }

    private var captureHelp: String {
        switch captureMode.wrappedValue {
        case 1: "Usage stays visible; account names and emails are blurred, and alerts leave them out."
        case 2: "Hides the notch and holds alerts, like for a full-screen app. An app that captures the screen all the time keeps it hidden."
        default: "A single screenshot cannot be detected; use the copy button for a picture without names."
        }
    }

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
            LabeledContent("Open notch from anywhere") {
                ShortcutRecorder(hotKey: $state.settings.toggleHotKey)
            }
            if state.hotKeyRefused {
                Text("macOS refused this shortcut. Another app may be using it.")
                    .font(.caption).foregroundStyle(.red)
            }
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
            if state.settings.pillMode == .rotate {
                Picker("Rotation animation", selection: $state.settings.pillRotateAnimation) {
                    ForEach(PillRotateAnimation.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Show each account for") {
                    HStack {
                        Slider(value: $state.settings.pillRotateInterval, in: 2...60, step: 1)
                        Text("\(Int(state.settings.pillRotateInterval)) s")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                LabeledContent("Animation speed") {
                    HStack {
                        Slider(value: $state.settings.pillRotateSpeed, in: 0.1...1.5, step: 0.05)
                        Text(String(format: "%.2f s", state.settings.pillRotateSpeed))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                if state.settings.expandTrigger == .click {
                    Text("Swipe two fingers over the collapsed notch to move by hand.")
                        .font(.caption).foregroundStyle(.secondary)
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
            Picker(selection: captureMode) {
                Text("Show as usual").tag(0)
                Text("Blur account names").tag(1)
                Text("Hide the notch").tag(2)
            } label: {
                Text("While the screen is shared or recorded")
                Text(captureHelp)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { state.settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Section("Updates") {
                LabeledContent("Version", value: Updater.version)
                if Updater.isAvailable {
                    Toggle("Check for updates daily", isOn: $updater.automaticallyChecks)
                    HStack {
                        Button("Check Now") { updater.checkNow() }
                            .disabled(!updater.canCheck)
                        Spacer()
                        if let last = updater.lastCheck {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Updates are available when running the app bundle (make run).")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

struct AlertsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Toggle("Drop alerts out of the notch", isOn: $state.settings.alertsEnabled)
            Section("Warn when a limit reaches") {
                ForEach([75, 90, 100], id: \.self) { t in
                    Toggle(t == 100 ? "100% (limit reached)" : "\(t)%", isOn: threshold(t))
                }
                Toggle("Tell me when a window resets", isOn: $state.settings.resetAlerts)
                Toggle("Warn when the pace runs a limit out before it resets", isOn: $state.settings.burningFastAlerts)
                    .help("Even below 75%. Once per window, again only after the pace is back on track.")
                Toggle("Remind me when a weekly limit resets mostly unused", isOn: $state.settings.useItOrLoseItAlerts)
                    .help("A window longer than a day that resets within 24 hours with more than half left.")
                Toggle("Sum up last week on Monday morning", isOn: $state.settings.weeklySummary)
            }
            .disabled(!state.settings.alertsEnabled)
            Toggle("Play a sound", isOn: $state.settings.alertSound)
                .disabled(!state.settings.alertsEnabled)
            QuietHoursSection(state: state)
            Section {
                Button("Show a test alert") { state.postTestAlert() }
                Text("Each threshold alerts once per window period. Alerts wait while the notch is open or an app is full screen, and are dropped during quiet hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func threshold(_ t: Int) -> Binding<Bool> {
        Binding(
            get: { state.settings.alertThresholds.contains(t) },
            set: { on in
                var ts = Set(state.settings.alertThresholds)
                if on { ts.insert(t) } else { ts.remove(t) }
                state.settings.alertThresholds = ts.sorted()
            }
        )
    }
}

/// Quiet hours, snooze status and the CLI hook for Focus automations.
private struct QuietHoursSection: View {
    @Bindable var state: AppState

    var body: some View {
        Section("Quiet hours") {
            Toggle("Silence alerts on a schedule", isOn: $state.settings.quietSchedule.enabled)
            if state.settings.quietSchedule.enabled {
                HStack {
                    DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("to", selection: time(\.end), displayedComponents: .hourAndMinute)
                }
                HStack(spacing: 4) {
                    Text("Starting on")
                    Spacer()
                    ForEach(weekdays, id: \.self) { day in
                        DayToggle(label: Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: dayBinding(day))
                    }
                }
            }
            Toggle("Let approvals and limit-reached alerts through", isOn: $state.settings.quietAllowUrgent)
            HStack {
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
                if state.settings.quietManual || (state.settings.snoozeUntil.map { $0 > Date() } ?? false) {
                    Button("Resume alerts") { state.resumeAlerts() }
                }
            }
            Text("To follow a macOS Focus, add a Shortcuts automation for that Focus that runs the shell command `agentilo quiet on` when it turns on and `agentilo quiet off` when it turns off. Install the command in Settings → Agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Weekdays in the user's order (Monday first where that is the custom).
    private var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var statusText: String {
        switch state.quietReason {
        case .manual: "Quiet until you turn it off"
        case .snoozed(let until): "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        case .schedule: "Quiet hours are on now"
        case nil: "Alerts are on"
        }
    }

    private func time(_ key: WritableKeyPath<QuietSchedule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = state.settings.quietSchedule[keyPath: key]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                state.settings.quietSchedule[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { state.settings.quietSchedule.days.contains(day) },
            set: { on in
                if on { state.settings.quietSchedule.days.insert(day) } else { state.settings.quietSchedule.days.remove(day) }
            }
        )
    }
}

private struct DayToggle: View {
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Button(label) { isOn.toggle() }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(isOn ? Color.white : Color.primary)
    }
}

struct AccountsTab: View {
    @Bindable var state: AppState
    @State private var selection: UUID?
    @State private var keySheet: APIKeyTarget?
    @State private var gheSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each agent home is one account. Limits are fetched per home; token statistics add up all enabled homes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($state.settings.accounts) { $acct in
                    AccountRow(account: $acct, status: state.status(acct)) {
                        keySheet = APIKeyTarget(account: acct.id)
                    }
                    .tag(acct.id)
                }
                .onMove { state.settings.accounts.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Menu {
                    ForEach(Provider.allCases) { p in
                        switch p {
                        case .copilot:
                            Button("Copilot (GitHub CLI login)") { addCopilot() }
                            Button("Copilot on GHE.com…") { gheSheet = true }
                        case .openRouter: Button("OpenRouter key…") { keySheet = APIKeyTarget(account: nil) }
                        case .opencode:
                            Button("OpenCode Go (CLI key)") {
                                state.settings.accounts.append(Account(
                                    provider: .opencode, homePath: OpenCodeProvider.defaultHome,
                                    label: Provider.opencode.displayName
                                ))
                                state.refreshAll(force: true)
                            }
                        default: Button("\(p.displayName) home…") { addAccount(p) }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()
                Button {
                    if let selection { KeychainStore.setAPIKey("", for: selection) }
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

            Divider().padding(.vertical, 2)
            ForEach(UnifiedAccounts.providers, id: \.self) { p in
                let n = state.limitAccounts.filter { $0.provider == p }.count
                if n > 1 {
                    Toggle("Show my \(n) \(p.displayName) accounts as one page", isOn: unified(p))
                        .help("Each limit once, averaged over the accounts; hover a limit for each account. Alerts and the collapsed notch stay per account.")
                }
            }
            Toggle("Suggest another account when one runs low", isOn: $state.settings.accountSuggestions)
            HStack {
                Picker("Open suggested accounts in", selection: $state.settings.preferredTerminal) {
                    ForEach(TerminalApp.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                .disabled(!state.settings.accountSuggestions)
                Spacer()
            }
            Text("At \(Int(AccountAdvisor.trigger))% of a window, the account page and the limit alert point to a home of the same agent with at least \(Int(AccountAdvisor.minGap)) points more room. iTerm2 and Terminal ask once for permission to be controlled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $gheSheet) {
            GHEHostSheet { host in addCopilot(host: host) }
        }
        .sheet(item: $keySheet) { target in
            APIKeySheet { key in
                if let id = target.account {
                    KeychainStore.setAPIKey(key, for: id)
                } else {
                    let account = Account(provider: .openRouter, homePath: "", label: Provider.openRouter.displayName)
                    KeychainStore.setAPIKey(key, for: account.id)
                    state.settings.accounts.append(account)
                }
                state.refreshAll(force: true)
            }
        }
    }

    private func unified(_ p: Provider) -> Binding<Bool> {
        Binding(
            get: { state.settings.unifiedProviders.contains(p) },
            set: { on in
                state.settings.unifiedProviders.removeAll { $0 == p }
                if on { state.settings.unifiedProviders.append(p) }
            }
        )
    }

    /// Never added by Detect homes: the GitHub CLI's token reaches much more than Copilot,
    /// so reading it is the user's choice.
    private func addCopilot(host: String = GitHubHost.dotCom) {
        let enterprise = host != GitHubHost.dotCom
        state.settings.accounts.append(Account(
            provider: .copilot, homePath: "~/.config/gh",
            label: enterprise ? "\(Provider.copilot.displayName) · \(host)" : Provider.copilot.displayName,
            host: enterprise ? host : nil
        ))
        state.refreshAll(force: true)
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
        case .gemini, .copilot, .openRouter, .opencode: panel.directoryURL = URL(fileURLWithPath: Paths.home)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = Paths.abbreviate(url.path)
        state.settings.accounts.append(Account(
            provider: provider, homePath: path, label: AccountDetector.defaultLabel(provider, url.path)
        ))
    }
}

/// Asks for the GitHub Enterprise Cloud domain; the GitHub CLI must be signed in to it.
private struct GHEHostSheet: View {
    var save: (String) -> Void
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    private var host: String? {
        GitHubHost.normalize(input).flatMap { $0 == GitHubHost.dotCom ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copilot on GHE.com").font(.headline)
            TextField("octocorp.ghe.com", text: $input)
                .textFieldStyle(.roundedBorder)
            Text(host.map { "Uses `gh auth login --hostname \($0)`. The token is sent only to api.\($0)." }
                 ?? "Your company's GHE.com domain, or just its name. Self-hosted GitHub Enterprise Server has no Copilot quota to read.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let host { save(host) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// Which account the key sheet is for; nil adds a new one.
private struct APIKeyTarget: Identifiable {
    let id = UUID()
    var account: UUID?
}

private struct APIKeySheet: View {
    var save: (String) -> Void
    @State private var key = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenRouter key").font(.headline)
            SecureField("sk-or-…", text: $key)
                .textFieldStyle(.roundedBorder)
            Text("A management key shows the credit balance; a standard key shows only its own limit. The key stays in your Keychain and goes only to openrouter.ai.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

struct AccountRow: View {
    @Binding var account: Account
    var status: AccountStatus
    var replaceKey: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $account.enabled).labelsHidden()
            ProviderIcon(provider: account.provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Label", text: $account.label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                Text(account.provider == .openRouter ? "Key in Keychain"
                     : account.host.map { "\(Paths.abbreviate(account.homePath)) · \($0)" } ?? Paths.abbreviate(account.homePath))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusText
            if account.provider == .openRouter {
                Button("Replace Key…", action: replaceKey).controlSize(.small)
            }
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
