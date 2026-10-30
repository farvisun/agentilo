import AgentiloCore
import AppKit
import Observation

struct AccountStatus: Equatable {
    var snapshot: UsageSnapshot?
    var error: String?
    var loading = false
}

/// Notch metrics of the screen the panel lives on.
struct NotchLayout: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32
    var hasNotch = false
}

@MainActor
@Observable
final class AppState {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            if settings.globalProxy != oldValue.globalProxy || settings.providerProxies != oldValue.providerProxies {
                proxyChanged()
            }
            // Renaming an account should not trigger a refetch.
            let fetchKey: (AppSettings) -> [String] = {
                $0.accounts.map { "\($0.id)|\($0.provider)|\($0.homePath)|\($0.enabled)|\($0.trackLimits)" }
            }
            if fetchKey(settings) != fetchKey(oldValue) {
                statuses = statuses.filter { id, _ in settings.accounts.contains { $0.id == id } }
                refreshAll(force: true)
                refreshStats()
            }
            if settings.refreshInterval != oldValue.refreshInterval { startLoop() }
            if settings.apiEnabled != oldValue.apiEnabled || settings.apiPort != oldValue.apiPort { startServer() }
            if settings.keepAwake != oldValue.keepAwake || settings.keepAwakeLidClosed != oldValue.keepAwakeLidClosed
                || settings.keepAwakeMinBattery != oldValue.keepAwakeMinBattery {
                updateKeepAwake()
            }
        }
    }

    var statuses: [UUID: AccountStatus] = [:]
    var stats = TokenStats()
    /// Opens the Reports window; set by the app delegate.
    @ObservationIgnored var openReports: () -> Void = {}
    var layout = NotchLayout()
    var expanded = false
    var page = 0
    var now = Date()
    let alerts = AlertCenter()
    var agents = AgentSessionStore()
    /// Permission prompts waiting for an answer in the notch, oldest first.
    var approvals: [PendingApproval] = []
    /// The notch is out of sight (an app is full screen on its display).
    var notchHidden = false
    /// What sleep is held off right now (Settings → Agents → Keep awake).
    var keepAwakeLevel = KeepAwakeLevel.off
    var keepAwakeHelperInstalled = KeepAwakeHelper.isInstalled
    @ObservationIgnored let sleepGuard = SleepGuard()

    var notchMode: NotchMode {
        if !approvals.isEmpty { return .approval }
        if expanded { return .expanded }
        return alerts.current.map { .alert(tall: $0.body != nil) } ?? .collapsed
    }

    @ObservationIgnored private let statsEngine = StatsEngine()
    @ObservationIgnored private var firedAlerts = AlertStore.load()
    @ObservationIgnored private var server: LocalServer?
    /// Why the local API is not serving, for Settings.
    var serverError: String?
    /// Last good server response per account, persisted for offline fallback.
    @ObservationIgnored private var stored: [UUID: StoredUsage] = SnapshotStore.load()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var proxies: [Provider: EffectiveProxy] = [:]
    @ObservationIgnored private var proxyDebounce: Task<Void, Never>?
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    @ObservationIgnored private var notBefore: [UUID: Date] = [:]
    @ObservationIgnored private var lastFetch: [UUID: Date] = [:]
    @ObservationIgnored var agentLoop: Task<Void, Never>?
    @ObservationIgnored let hookToken = HookToken.ensure()
    @ObservationIgnored var approvalWaiters: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]

    init() {
        var s = SettingsStore.load()
        if s.accounts.isEmpty {
            s.accounts = AccountDetector.detect()
            SettingsStore.save(s)
        }
        settings = s
        alerts.allows = { [unowned self] alert in self.allowsAlert(alert) }
        resolveProxies()
        // Show something immediately: last response from disk or Codex's own logs.
        for acct in s.accounts where acct.enabled && acct.trackLimits {
            if let snap = LocalUsage.fallback(for: acct, stored: stored[acct.id], engine: statsEngine) {
                statuses[acct.id] = AccountStatus(snapshot: snap)
            }
        }
    }

    // MARK: Derived

    /// Accounts shown as pages in the expanded notch.
    var limitAccounts: [Account] { settings.accounts.filter { $0.enabled && $0.trackLimits } }

    /// Pages of the expanded notch, in order.
    var pages: [NotchPage] {
        (agents.sessions.isEmpty ? [] : [.agents]) + limitAccounts.map { .account($0) }
            + (settings.showTokenStats ? [.stats, .activity, .reports] : [])
    }

    var pageCount: Int { pages.count }

    /// The account and window closest to trouble: worst pace first, then highest usage.
    var critical: (account: Account, window: UsageWindow)? { critical(provider: nil) }

    func critical(provider: Provider?) -> (account: Account, window: UsageWindow)? {
        var best: (Account, UsageWindow)?
        for acct in limitAccounts where provider == nil || acct.provider == provider {
            guard let w = statuses[acct.id]?.snapshot?.window(for: settings.pillWindow, now: now) else { continue }
            if let (_, b) = best {
                let sa = w.pace(now: now).severity, sb = b.pace(now: now).severity
                if sa < sb || (sa == sb && w.usedPercent <= b.usedPercent) { continue }
            }
            best = (acct, w)
        }
        return best.map { ($0.0, $0.1) }
    }

    func status(_ account: Account) -> AccountStatus { statuses[account.id] ?? AccountStatus() }

    /// Debug: the page index for `--preview-page`.
    func previewPage(_ name: String) -> Int? {
        switch name {
        case "last": return pageCount - 1
        case "reports": return pages.firstIndex(of: .reports)
        case "switch":
            return pages.firstIndex { if case .account(let a) = $0 { suggestion(from: a) != nil } else { false } }
        default: return Int(name)
        }
    }

    /// A sibling with room to spare for this account, when it is running low.
    func suggestion(from account: Account) -> AccountSuggestion? {
        guard settings.accountSuggestions else { return nil }
        return AccountAdvisor.suggest(
            accounts: limitAccounts, snapshots: statuses.compactMapValues(\.snapshot), now: now
        ).first { $0.from.id == account.id }
    }

    /// What the collapsed pill shows, per the pill mode. One entry fills both wings; two split them.
    var pillItems: [(account: Account, window: UsageWindow)] {
        switch settings.pillMode {
        case .mostCritical:
            return critical.map { [$0] } ?? []
        case .pinned:
            if let id = settings.pinnedAccount, let acct = limitAccounts.first(where: { $0.id == id }),
               let w = status(acct).snapshot?.window(for: settings.pillWindow, now: now) {
                return [(acct, w)]
            }
            return critical.map { [$0] } ?? []
        case .perProvider:
            let items = Provider.allCases.compactMap { critical(provider: $0) }
                .sorted { a, b in
                    let sa = a.window.pace(now: now).severity, sb = b.window.pace(now: now).severity
                    return sa != sb ? sa > sb : a.window.usedPercent > b.window.usedPercent
                }
            // Two wings: keep the two most critical providers, in a stable left-to-right order.
            return Array(items.prefix(2)).sorted { a, b in
                Provider.allCases.firstIndex(of: a.account.provider)! < Provider.allCases.firstIndex(of: b.account.provider)!
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        startLoop()
        startServer()
        startAgents()
        refreshStats()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll(force: true)
                self?.refreshStats()
            }
        }
    }

    private func startLoop() {
        loop?.cancel()
        let interval = max(30, settings.refreshInterval)
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.now = Date()
                if tick % Int(interval / 15) == 0 { self?.refreshAll(force: false) }
                if tick % 4 == 0 { self?.refreshStats() }
                tick += 1
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Called when the notch opens: fetch anything older than a minute.
    func expandedRefresh() {
        now = Date()
        // Open on the agents when one is waiting, on the reports over the weekly summary.
        if agents.attentionCount > 0 {
            page = 0
        } else if alerts.read?.opensReports == true,
                  let i = pages.firstIndex(of: .reports) {
            page = i
        }
        for acct in limitAccounts where Date().timeIntervalSince(lastFetch[acct.id] ?? .distantPast) > 60 {
            refresh(acct, force: false)
        }
        refreshStats()
    }

    func refreshAll(force: Bool) {
        for acct in limitAccounts { refresh(acct, force: force) }
    }

    func refresh(_ account: Account, force: Bool) {
        let id = account.id
        if !force, let nb = notBefore[id], nb > Date() { return }
        if statuses[id]?.loading == true { return }
        statuses[id, default: AccountStatus()].loading = true
        lastFetch[id] = Date()
        let proxy = proxies[account.provider] ?? EffectiveProxy(config: ProxyConfig())
        let previous = stored[id]
        let engine = statsEngine
        Task.detached {
            let session = SessionFactory.shared.session(for: proxy)
            let result: Result<StoredUsage, Error>
            var fallback: UsageSnapshot?
            do {
                let snap = try await UsageProviders.provider(for: account.provider).fetch(account: account, session: session)
                let cal = LocalUsage.calibrate(snap, account: account, engine: engine, previous: previous?.calibration ?? [:])
                result = .success(StoredUsage(snapshot: snap, calibration: cal))
            } catch {
                result = .failure(error)
                fallback = LocalUsage.fallback(for: account, stored: previous, engine: engine)
            }
            let offline = fallback
            await MainActor.run { self.apply(result, fallback: offline, to: id) }
        }
    }

    private func apply(_ result: Result<StoredUsage, Error>, fallback: UsageSnapshot?, to id: UUID) {
        var st = statuses[id] ?? AccountStatus()
        let old = st.snapshot
        st.loading = false
        switch result {
        case .success(let usage):
            st.snapshot = usage.snapshot
            st.error = nil
            failures[id] = 0
            notBefore[id] = nil
            stored[id] = usage
            stored = stored.filter { key, _ in settings.accounts.contains { $0.id == key } }
            SnapshotStore.save(stored)
        case .failure(let error):
            st.error = error.localizedDescription
            if let fallback { st.snapshot = fallback }
            let transient = (error as? UsageError)?.isTransient ?? true
            if transient {
                let n = (failures[id] ?? 0) + 1
                failures[id] = n
                notBefore[id] = Date().addingTimeInterval(min(1_800, 30 * pow(2, Double(n))))
            }
        }
        statuses[id] = st
        now = Date()
        if let snap = st.snapshot { checkAlerts(id, old: old, new: snap) }
    }

    // MARK: Alerts

    private func checkAlerts(_ id: UUID, old: UsageSnapshot?, new: UsageSnapshot) {
        guard settings.alertsEnabled, let acct = settings.accounts.first(where: { $0.id == id }) else { return }
        let before = firedAlerts
        let found = AlertEngine.evaluate(
            previous: old, current: new, account: acct,
            thresholds: settings.alertThresholds, resetAlerts: settings.resetAlerts,
            fired: &firedAlerts, now: now
        )
        if firedAlerts != before { AlertStore.save(firedAlerts) }
        let switchTo = suggestion(from: acct).map { "Switch: \($0.reason)" }
        for a in found {
            var alert = NotchAlert(a, sound: settings.alertSound, now: now)
            if a.kind != .reset { alert.body = switchTo }
            alerts.post(alert)
        }
    }

    /// From Monday 09:00, once per week: last week's cost, tokens and top project.
    /// Quiet hours postpone it rather than drop it.
    func checkWeeklySummary() {
        guard settings.weeklySummary, quietReason == nil, stats.computedAt != .distantPast else { return }
        let now = Date(), cal = Calendar.current
        let lastWeek = ReportBuilder.lastWeekStart(now: now)
        let thisWeek = cal.date(byAdding: .day, value: 7, to: lastWeek)!
        let key = "weekly|\(DayKey.int(lastWeek))"
        guard now >= thisWeek.addingTimeInterval(9 * 3_600), firedAlerts[key] == nil else { return }
        firedAlerts[key] = now
        AlertStore.save(firedAlerts)
        let sunday = cal.date(byAdding: .day, value: -1, to: thisWeek)!
        let report = ReportBuilder.report(history: stats.history, days: 7, end: sunday, groupBy: .project)
        guard report.total.tokens > 0 else { return }
        alerts.post(NotchAlert(weekly: report, streak: stats.currentStreak))
    }

    // MARK: Quiet hours

    /// Why alerts are silent right now, if they are.
    var quietReason: QuietReason? { settings.quietReason(now: Date()) }

    func allowsAlert(_ alert: NotchAlert) -> Bool {
        guard quietReason != nil else { return true }
        return alert.urgent && settings.quietAllowUrgent
    }

    /// Snooze from the notch or the CLI. `nil` minutes means until turned off.
    func setQuiet(minutes: Int?) {
        if let minutes {
            settings.quietManual = false
            settings.snoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            settings.quietManual = true
        }
    }

    func setQuiet(until date: Date) {
        settings.quietManual = false
        settings.snoozeUntil = date
    }

    /// Ends a snooze or manual quiet. A schedule stays in effect.
    func resumeAlerts() {
        settings.quietManual = false
        settings.snoozeUntil = nil
    }

    /// Settings → Alerts → "Show a test alert".
    func postTestAlert() {
        let provider = limitAccounts.first?.provider ?? .claude
        alerts.post(NotchAlert(
            provider: provider, title: "\(provider.displayName) session at 90%",
            message: "Runs out \(Formatters.resetTime(Date().addingTimeInterval(2_700))) · test alert",
            color: Palette.red, sound: settings.alertSound ? "Funk" : nil
        ))
    }

    func refreshStats() {
        guard settings.showTokenStats, statsTask == nil else { return }
        let accounts = settings.accounts
        let engine = statsEngine
        // Accounts showing offline numbers get re-estimated from the fresh scan.
        let offline = limitAccounts.filter { (statuses[$0.id]?.snapshot?.source ?? .live) != .live }
        let storedNow = stored
        statsTask = Task.detached(priority: .utility) {
            let s = engine.compute(accounts: accounts)
            var updates: [UUID: UsageSnapshot] = [:]
            for acct in offline {
                updates[acct.id] = LocalUsage.fallback(for: acct, stored: storedNow[acct.id], engine: engine)
            }
            let refreshed = updates
            await MainActor.run {
                self.stats = s
                self.checkWeeklySummary()
                for (id, snap) in refreshed where self.statuses[id]?.snapshot?.source != .live {
                    let old = self.statuses[id]?.snapshot
                    self.statuses[id]?.snapshot = snap
                    self.checkAlerts(id, old: old, new: snap)
                }
                self.statsTask = nil
            }
        }
    }

    // MARK: Local API

    private func startServer() {
        server?.stop()
        server = nil
        serverError = nil
        guard settings.apiEnabled else { return }
        guard let port = UInt16(exactly: settings.apiPort), port >= 1024 else {
            serverError = "Port must be between 1024 and 65535"
            return
        }
        let s = LocalServer(port: port) { [weak self] req in
            await self?.handle(req) ?? .error(503, "shutting down")
        }
        do {
            try s.start()
            server = s
        } catch {
            serverError = "Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)"
        }
    }

    private func handle(_ req: HTTPRequest) async -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/v1/health"):
            return .json(["ok": true])
        case ("GET", "/v1/limits"):
            if req.query["refresh"] != nil {
                refreshAll(force: true)
                // Wait for the fetches, but never hold a status line hostage.
                for _ in 0..<60 where limitAccounts.contains(where: { statuses[$0.id]?.loading == true }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            return .json(limitsPayload())
        case ("POST", "/v1/events"):
            guard (req.headers[HookToken.header] ?? req.headers[HookToken.legacyHeader]) == hookToken else { return .error(401, "bad token") }
            guard let event = try? APIJSON.decoder.decode(AgentEvent.self, from: req.body) else {
                return .error(400, "bad event")
            }
            receive(event)
            return .json(["ok": true])
        case ("POST", "/v1/permission"):
            guard (req.headers[HookToken.header] ?? req.headers[HookToken.legacyHeader]) == hookToken else { return .error(401, "bad token") }
            guard let request = try? APIJSON.decoder.decode(ApprovalRequest.self, from: req.body) else {
                return .error(400, "bad request")
            }
            return .json(ApprovalResponse(decision: await requestApproval(request)))
        case ("POST", "/v1/quiet"):
            guard (req.headers[HookToken.header] ?? req.headers[HookToken.legacyHeader]) == hookToken else { return .error(401, "bad token") }
            guard let request = try? APIJSON.decoder.decode(QuietRequest.self, from: req.body) else {
                return .error(400, "bad request")
            }
            if request.action != .status { request.apply(to: &settings) }
            return .json(QuietStatus(quietReason))
        case ("POST", "/v1/awake"):
            guard (req.headers[HookToken.header] ?? req.headers[HookToken.legacyHeader]) == hookToken else { return .error(401, "bad token") }
            guard let request = try? APIJSON.decoder.decode(AwakeRequest.self, from: req.body) else {
                return .error(400, "bad request")
            }
            if request.action != .status { request.apply(to: &settings) }
            return .json(awakeStatus)
        case (_, "/v1/health"), (_, "/v1/limits"), (_, "/v1/events"), (_, "/v1/permission"), (_, "/v1/quiet"), (_, "/v1/awake"):
            return .error(405, "method not allowed")
        default:
            return .error(404, "not found")
        }
    }

    func limitsPayload() -> LimitsPayload {
        LimitsPayload.build(
            accounts: limitAccounts,
            snapshots: statuses.compactMapValues(\.snapshot),
            errors: statuses.compactMapValues(\.error),
            includeLabels: settings.apiIncludeLabels,
            origin: "app",
            now: Date()
        )
    }

    // MARK: Proxy

    func proxy(for p: Provider) -> EffectiveProxy { proxies[p] ?? settings.effectiveProxy(for: p) }

    /// Debounced so typing a host or port does not fire a request per keystroke.
    func proxyChanged() {
        proxyDebounce?.cancel()
        proxyDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.resolveProxies()
            SessionFactory.shared.reset()
            self.refreshAll(force: true)
        }
    }

    private func resolveProxies() {
        for p in Provider.allCases { proxies[p] = settings.effectiveProxy(for: p) }
    }

    // MARK: Pages

    func movePage(_ delta: Int) {
        guard pageCount > 0 else { return }
        page = (page + delta + pageCount) % pageCount
    }
}
