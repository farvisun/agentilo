import AgentiloCore
import Charts
import SwiftUI

struct ExpandedView: View {
    @Bindable var state: AppState
    var openSettings: () -> Void

    var body: some View {
        let l = state.layout
        VStack(spacing: 0) {
            topBar
                .frame(height: l.notchHeight)

            Group {
                let pages = state.pages
                switch pages.isEmpty ? nil : pages[min(state.page, pages.count - 1)] {
                case nil:
                    EmptyPage(openSettings: openSettings)
                case .agents:
                    AgentsPage(state: state)
                case .account(let acct):
                    AccountPage(
                        account: acct, status: state.status(acct), stats: state.stats,
                        mode: state.settings.displayMode, now: state.now,
                        suggestion: state.suggestion(from: acct), terminal: state.settings.preferredTerminal
                    )
                        .id(acct.id)
                case .stats:
                    StatsPage(stats: state.stats)
                case .activity:
                    ActivityPage(stats: state.stats)
                case .reports:
                    ReportsPage(stats: state.stats, openReports: state.openReports)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)

            pageDots
                .padding(.bottom, 10)
        }
    }

    /// Items sit on either side of the notch.
    private var topBar: some View {
        let l = state.layout
        let sideWidth = (NotchGeometry.expandedSize(l).width - 20 - l.notchWidth) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Agentilo")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
            }
            .frame(width: sideWidth)

            Spacer().frame(width: l.notchWidth)

            HStack(spacing: 2) {
                Spacer(minLength: 0)
                IconButton(symbol: "chevron.left", help: "Previous") { withAnimation(.snappy) { state.movePage(-1) } }
                IconButton(symbol: "chevron.right", help: "Next") { withAnimation(.snappy) { state.movePage(1) } }
                IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                    state.refreshAll(force: true)
                    state.refreshStats()
                }
                QuietMenu(state: state)
                AwakeMenu(state: state)
                IconButton(symbol: "gearshape", help: "Settings") { openSettings() }
                IconButton(symbol: "power", help: "Quit Agentilo") { NSApp.terminate(nil) }
                    .padding(.trailing, 8)
            }
            .frame(width: sideWidth)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<state.pageCount, id: \.self) { i in
                Circle()
                    .fill(i == state.page ? Color.white.opacity(0.85) : Color.white.opacity(0.22))
                    .frame(width: 5, height: 5)
                    .onTapGesture { withAnimation(.snappy) { state.page = i } }
            }
        }
        .opacity(state.pageCount > 1 ? 1 : 0)
    }
}

/// Snooze alerts from the notch.
private struct QuietMenu: View {
    var state: AppState
    @State private var hover = false

    var body: some View {
        let quiet = state.settings.quietReason(now: state.now) != nil
        Menu {
            Button("Snooze for 1 hour") { state.setQuiet(minutes: 60) }
            Button("Snooze until tomorrow, 8:00") { state.setQuiet(until: Self.tomorrowMorning()) }
            Button("Quiet until I turn it back on") { state.setQuiet(minutes: nil) }
            if quiet {
                Divider()
                Button("Resume alerts") { state.resumeAlerts() }
            }
        } label: {
            Image(systemName: quiet ? "moon.fill" : "moon")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(quiet ? Palette.amber : (hover ? Color.white : Palette.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help(quiet ? "Alerts are snoozed" : "Snooze alerts")
    }

    static func tomorrowMorning(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// Keep the Mac awake while agents work. The cup fills while it is holding sleep off.
private struct AwakeMenu: View {
    @Bindable var state: AppState
    @State private var hover = false

    var body: some View {
        let holding = state.keepAwakeLevel != .off
        Menu {
            Toggle("Keep awake while agents work", isOn: $state.settings.keepAwake)
            if state.keepAwakeHelperInstalled {
                Toggle("Also with the lid closed", isOn: $state.settings.keepAwakeLidClosed)
                    .disabled(!state.settings.keepAwake)
            } else {
                Button("Lid closed: install the helper in Settings") {}
                    .disabled(true)
            }
            if state.settings.keepAwake {
                Divider()
                Button(Self.statusText(state.keepAwakeLevel, working: state.workingAgents)) {}
                    .disabled(true)
            }
        } label: {
            Image(systemName: holding ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(holding ? Palette.green : (hover ? Color.white : Palette.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help(holding ? "Keeping the Mac awake while agents work" : "Keep awake while agents work")
    }

    static func statusText(_ level: KeepAwakeLevel, working: Int) -> String {
        switch level {
        case .off: working > 0 ? "Not holding: battery low" : "Waiting for an agent to work"
        case .idle: "Holding idle sleep off"
        case .lidClosed: "Holding all sleep off, lid closed too"
        }
    }
}

struct AccountPage: View {
    var account: Account
    var status: AccountStatus
    var stats: TokenStats
    var mode: UsageDisplay
    var now: Date
    var suggestion: AccountSuggestion? = nil
    var terminal: TerminalApp = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snap = status.snapshot, !snap.windows.isEmpty {
                VStack(spacing: 9) {
                    ForEach(snap.windows.prefix(3)) { w in
                        WindowRow(window: w, mode: mode, estimated: snap.source == .estimated, now: now)
                    }
                }
            } else if status.loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking with \(account.provider.displayName)…")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text(status.error ?? "No limits reported yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            if let suggestion {
                SwitchRow(suggestion: suggestion, terminal: terminal)
            } else {
                footer
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: account.provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.provider.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(account.label)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let plan = status.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            if status.loading && status.snapshot != nil {
                ProgressView().controlSize(.mini)
            }
            if let err = status.error, status.snapshot != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.amber)
                    .help(err)
            }
            if let snap = status.snapshot {
                Text(sourceText(snap))
                    .font(.system(size: 10))
                    .foregroundStyle(snap.source == .live ? Palette.tertiary : Palette.amber)
                    .help(status.error ?? "")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let live = stats.live.filter { $0.provider == account.provider }.first
        let today = stats.todayByProvider[account.provider] ?? 0
        HStack(spacing: 10) {
            if let live {
                Circle().fill(Palette.green).frame(width: 6, height: 6)
                Text(live.project).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(Formatters.duration(live.last.timeIntervalSince(live.start)))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
                Text("\(Formatters.compactTokens(live.tokens)) tokens")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if today > 0 {
                Text("Today \(Formatters.compactTokens(today)) tokens")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func sourceText(_ snap: UsageSnapshot) -> String {
        let age = ago(snap.fetchedAt)
        switch snap.source {
        case .live: return age
        case .cached: return "cached · \(age)"
        case .localLog: return "from Codex logs · \(age)"
        case .estimated: return "≈ estimated from logs"
        }
    }

    private func ago(_ date: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3_600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3_600)h ago" }
        return "\(s / 86_400)d ago"
    }
}

/// "Switch to Work · 88% left": copies the command that starts the agent on that account.
private struct SwitchRow: View {
    var suggestion: AccountSuggestion
    var terminal: TerminalApp
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.green)
            Text("Switch to \(suggestion.to.label)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text("\(Int((100 - suggestion.toUsed).rounded()))% left")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.secondary)
            Spacer()
            if let command = suggestion.command {
                Button(copied ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .help(command)
                if terminal != .none {
                    Button("Open in \(terminal.displayName)") { TerminalLauncher.open(command, in: terminal) }
                        .help(command)
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }
}

struct WindowRow: View {
    var window: UsageWindow
    var mode: UsageDisplay
    var estimated: Bool
    var now: Date

    var body: some View {
        let pace = window.pace(now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(percentText)
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pace.color)
                if let detail = window.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Text(pace.label(now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pace.color)
                if let reset = window.resetsAt, !isLimit(pace) {
                    Text("resets \(Formatters.resetTime(reset, now: now)) · \(Formatters.countdown(to: reset, now: now))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Palette.tertiary)
                }
            }
            MeterBar(
                fraction: mode.value(window.usedPercent) / 100,
                color: pace.color,
                expected: window.elapsedFraction(now: now).map { mode == .used ? $0 : 1 - $0 }
            )
        }
    }

    private var percentText: String {
        let value = Int(mode.value(window.usedPercent).rounded())
        return "\(estimated ? "≈" : "")\(value)%\(mode == .remaining ? " left" : "")"
    }

    private func isLimit(_ p: Pace) -> Bool {
        if case .limitReached = p { return true }
        return false
    }
}

struct StatsPage: View {
    var stats: TokenStats

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Text(Formatters.compactTokens(stats.today))
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                Text("tokens · ≈ \(String(format: "$%.2f", stats.todayCost))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
                ForEach(Provider.allCases.filter { (stats.todayByProvider[$0] ?? 0) > 0 }) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.tint).frame(width: 6, height: 6)
                        Text(p.displayName).font(.system(size: 10))
                        Spacer()
                        Text(Formatters.compactTokens(stats.todayByProvider[p] ?? 0))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.secondary)
                    }
                }
            }
            .frame(width: 110)

            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Chart {
                    ForEach(stats.days) { day in
                        ForEach(Provider.allCases) { p in
                            BarMark(
                                x: .value("Day", day.day, unit: .day),
                                y: .value("Tokens", day.byProvider[p] ?? 0)
                            )
                            .foregroundStyle(by: .value("Agent", p.displayName))
                            .cornerRadius(2)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: Provider.allCases.map(\.displayName), range: Provider.allCases.map(\.tint))
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Palette.track)
                        AxisValueLabel {
                            if let n = v.as(Int.self) { Text(Formatters.compactTokens(n)).font(.system(size: 8)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.system(size: 8))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text("30-day models").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                let top = Array(stats.models.prefix(5))
                let total = max(1, stats.models.reduce(0) { $0 + $1.tokens })
                ForEach(top) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.model).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Formatters.compactTokens(m.tokens))
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.secondary)
                        }
                        MeterBar(fraction: Double(m.tokens) / Double(total), color: Color.white.opacity(0.6))
                            .frame(height: 3)
                    }
                }
                if top.isEmpty {
                    Text("No sessions logged").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
            }
            .frame(width: 150)
        }
    }
}

struct EmptyPage: View {
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("No agent homes configured").font(.system(size: 12, weight: .medium))
            Button("Open Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
