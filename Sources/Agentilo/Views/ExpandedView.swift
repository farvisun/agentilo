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
                        mode: state.settings.displayMode, now: state.now
                    )
                        .id(acct.id)
                case .stats:
                    StatsPage(stats: state.stats)
                case .activity:
                    ActivityPage(stats: state.stats)
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

struct AccountPage: View {
    var account: Account
    var status: AccountStatus
    var stats: TokenStats
    var mode: UsageDisplay
    var now: Date

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
            footer
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
