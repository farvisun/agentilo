@testable import AgentiloCore
import Foundation
import XCTest

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func fixtureJSON(_ name: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
}

final class PaceTests: XCTestCase {
    let reset = Date(timeIntervalSince1970: 1_000_000)
    let length: TimeInterval = 5 * 3_600

    private func pace(_ used: Double, elapsedFraction: Double) -> Pace {
        let now = reset.addingTimeInterval(-length * (1 - elapsedFraction))
        return Pace.evaluate(usedPercent: used, resetsAt: reset, windowLength: length, now: now)
    }

    func testOnTrackWhenUsageFollowsClock() {
        XCTAssertEqual(pace(50, elapsedFraction: 0.5), .onTrack)
        XCTAssertEqual(pace(54, elapsedFraction: 0.5), .onTrack)
    }

    func testRunsOutBeforeReset() {
        // 60% after one hour of five: 100% after ~1h40m.
        let p = pace(60, elapsedFraction: 0.2)
        guard case .runsOut(let date) = p else { return XCTFail("expected runsOut, got \(p)") }
        let now = reset.addingTimeInterval(-length * 0.8)
        XCTAssertEqual(date.timeIntervalSince(now), 2_400, accuracy: 1)
    }

    func testAheadWhenSlightlyOverTheClock() {
        XCTAssertEqual(pace(60, elapsedFraction: 0.50), .ahead)
        XCTAssertEqual(pace(62, elapsedFraction: 0.50), .ahead)
        guard case .runsOut = pace(63, elapsedFraction: 0.50) else { return XCTFail() }
    }

    func testLimitReachedAndUnknown() {
        XCTAssertEqual(pace(100, elapsedFraction: 0.3), .limitReached(resetsAt: reset))
        XCTAssertEqual(Pace.evaluate(usedPercent: 10, resetsAt: nil, windowLength: nil), .unknown)
    }

    func testSeverityOrdering() {
        XCTAssertLessThan(Pace.onTrack.severity, Pace.ahead.severity)
        XCTAssertLessThan(Pace.ahead.severity, Pace.runsOut(Date()).severity)
        XCTAssertLessThan(Pace.runsOut(Date()).severity, Pace.limitReached(resetsAt: nil).severity)
    }
}

final class PillWindowTests: XCTestCase {
    private func window(_ id: String, _ kind: WindowKind, _ used: Double) -> UsageWindow {
        UsageWindow(id: id, kind: kind, title: id, usedPercent: used, resetsAt: nil, windowLength: nil)
    }

    func testPicksChosenKindAndFallsBack() {
        let snap = UsageSnapshot(windows: [
            window("session", .session, 20), window("weekly", .weekly, 40), window("opus", .weekly, 70),
        ])
        XCTAssertEqual(snap.window(for: .session)?.id, "session")
        XCTAssertEqual(snap.window(for: .weekly)?.id, "opus")
        XCTAssertEqual(snap.window(for: .mostCritical)?.id, "opus")

        let billing = UsageSnapshot(windows: [window("plan", .billing, 30)])
        XCTAssertEqual(billing.window(for: .session)?.id, "plan")
    }
}

final class ProviderParsingTests: XCTestCase {
    func testClaudeLimitsArray() throws {
        let snap = ClaudeProvider.parse(try fixtureJSON("claude_usage.json"))
        XCTAssertEqual(snap.windows.map(\.title), ["Session", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(snap.windows.map(\.kind), [.session, .weekly, .weekly])
        XCTAssertEqual(snap.windows[0].usedPercent, 3)
        XCTAssertEqual(snap.windows[0].windowLength, 5 * 3_600)
        let reset = try XCTUnwrap(snap.windows[0].resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, DateParsing.iso("2026-10-22T13:10:00Z")!.timeIntervalSince1970 + 0.493256, accuracy: 0.001)
    }

    func testClaudeLegacyFields() throws {
        let snap = ClaudeProvider.parse(try fixtureJSON("claude_usage_legacy.json"))
        XCTAssertEqual(snap.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snap.primary?.usedPercent, 42.5)
    }

    func testCodexClassifiesWindowsByLength() throws {
        let snap = CodexProvider.parse(try fixtureJSON("codex_usage.json"))
        XCTAssertEqual(snap.windows.map(\.title), ["Session", "Weekly"])
        XCTAssertEqual(snap.windows.first?.usedPercent, 12)
        XCTAssertEqual(snap.plan, "Pro Lite")
        XCTAssertEqual(snap.email, "dev@example.com")
        XCTAssertEqual(snap.windows.last?.resetsAt, Date(timeIntervalSince1970: 1_793_082_740))
    }

    func testCursorBilling() throws {
        let snap = CursorProvider.parse(try fixtureJSON("cursor_usage.json"))
        XCTAssertEqual(snap.windows.map(\.id), ["plan", "on_demand"])
        XCTAssertEqual(snap.windows[0].usedPercent, 75)
        XCTAssertEqual(snap.windows[0].detail, "$15.00 of $20.00")
        XCTAssertEqual(snap.windows[1].usedPercent, 25)
        XCTAssertEqual(snap.windows[0].windowLength, 31 * 86_400)
        XCTAssertEqual(snap.plan, "Pro")
    }

    func testISODateWithMicroseconds() {
        let d = DateParsing.iso("2026-10-22T13:10:00.489653+00:00")
        XCTAssertNotNil(d)
        XCTAssertEqual(DateParsing.iso("2026-10-22T13:10:00Z")?.timeIntervalSince1970, 1_792_674_600)
    }
}

final class KeychainNameTests: XCTestCase {
    func testDefaultHomeHasNoSuffix() {
        XCTAssertEqual(ClaudeCredentials.keychainService(forHome: "~/.claude"), "Claude Code-credentials")
    }

    func testCustomHomeIsHashed() {
        // sha256("/Users/dev/.claude_multi/work") starts with 78bbac24.
        XCTAssertEqual(
            ClaudeCredentials.keychainService(forHome: "/Users/dev/.claude_multi/work/"),
            "Claude Code-credentials-78bbac24"
        )
    }
}

final class LogParserTests: XCTestCase {
    func testClaudeDedupesStreamingWrites() throws {
        let agg = ClaudeLogParser.parse(try fixture("claude_session.jsonl"))
        XCTAssertEqual(agg.totalTokens, 100 + 3)
        XCTAssertEqual(agg.project, "web-app")
        XCTAssertEqual(Set(agg.models), ["claude-opus-5-5", "claude-haiku-5-5"])
    }

    func testCodexUsesDeltas() throws {
        let agg = CodexLogParser.parse(try fixture("codex_session.jsonl"))
        XCTAssertEqual(agg.totalTokens, 1_600)
        XCTAssertEqual(agg.models, ["gpt-6.1-sol"])
        XCTAssertEqual(agg.project, "api-server")
    }

    func testIncrementalParseMatchesFullParse() throws {
        let data = try fixture("codex_session.jsonl")
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let firstPart = Data(lines.prefix(3).joined(separator: [0x0A])) + Data([0x0A]) + Data("{\"partial".utf8)
        var agg = FileAggregate()
        let consumed = CodexLogParser.parse(firstPart, into: &agg)
        XCTAssertEqual(agg.totalTokens, 1_000)
        _ = CodexLogParser.parse(data.subdata(in: consumed..<data.count), into: &agg)
        XCTAssertEqual(agg.totalTokens, CodexLogParser.parse(data).totalTokens)
    }

    func testSummaryDedupesAcrossFiles() throws {
        let agg = ClaudeLogParser.parse(try fixture("claude_session.jsonl"))
        var copy = agg
        copy.firstTimestamp = agg.firstTimestamp?.addingTimeInterval(3_600)
        let now = try XCTUnwrap(DateParsing.iso("2026-10-20T12:00:00Z"))
        let stats = StatsEngine.summarize([("a", .claude, agg), ("b", .claude, copy)], now: now)
        XCTAssertEqual(stats.models.reduce(0) { $0 + $1.tokens }, 103)
        XCTAssertEqual(stats.days.map(\.total).reduce(0, +), 103)
    }
}

final class ReportTests: XCTestCase {
    private func codexLine(_ ts: String, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
    }

    func testCodexDeltasArePricedByKind() {
        let log = [
            #"{"timestamp":"2026-10-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            codexLine("2026-10-20T10:01:00Z", input: 1_000_000, cached: 800_000, output: 10_000),
            codexLine("2026-10-20T10:01:01Z", input: 1_000_000, cached: 800_000, output: 10_000),
            codexLine("2026-10-20T10:02:00Z", input: 2_000_000, cached: 1_800_000, output: 20_000),
        ].joined(separator: "\n") + "\n"
        let agg = CodexLogParser.parse(Data(log.utf8))
        XCTAssertEqual(agg.totalTokens, 2_020_000)
        // First: 200K uncached x $2 + 800K cached x $0.10 + 10K out x $10 = $0.58.
        // The repeat adds nothing; the last adds 1M cached ($0.10) + 10K out ($0.10).
        XCTAssertEqual(agg.entries.compactMap(\.c).reduce(0, +), 0.78, accuracy: 0.0001)
        // Totals alone, as in older logs: counted, not priced.
        XCTAssertTrue(CodexLogParser.parse(try! fixture("codex_session.jsonl")).entries.allSatisfy { $0.c == nil })
    }

    func testSummaryRecordsBreakdowns() throws {
        let agg = ClaudeLogParser.parse(try fixture("claude_session.jsonl"))
        let now = try XCTUnwrap(DateParsing.iso("2026-10-20T12:00:00Z"))
        let stats = StatsEngine.summarize([("a", .claude, agg)], now: now)
        let day = try XCTUnwrap(stats.history.first { $0.active })
        XCTAssertEqual(day.projects?.values.reduce(0) { $0 + $1.tokens }, day.tokens)
        XCTAssertEqual(day.providers?["claude"]?.tokens, day.tokens)
        XCTAssertEqual(day.providers?["claude"]?.prompts, day.prompts)
        XCTAssertEqual(day.models?.values.reduce(0) { $0 + $1.tokens }, day.tokens)
    }

    func testOldHistoryDecodesWithoutBreakdowns() throws {
        let old = try JSONDecoder().decode([DayRecord].self, from: Data(#"[{"day":20260301,"tokens":5,"cost":0.5,"prompts":1,"tools":2}]"#.utf8))
        XCTAssertEqual(old.first?.tokens, 5)
        XCTAssertNil(old.first?.projects)
    }

    func testReportComparesPeriodsAndGroups() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let end = try XCTUnwrap(DateParsing.iso("2026-10-28T15:00:00Z"))
        func day(_ back: Int, _ projects: [String: Int]?, tokens: Int? = nil) -> DayRecord {
            let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: end))!
            var r = DayRecord(day: DayKey.int(d, calendar: cal))
            r.tokens = tokens ?? projects!.values.reduce(0, +)
            r.cost = Double(r.tokens) / 100
            r.projects = projects?.mapValues { DayUsage(tokens: $0, cost: Double($0) / 100) }
            return r
        }
        let history = [
            day(0, ["api": 300, "web": 100]),
            day(6, ["api": 100, "cli": 50, "docs": 10]),
            day(7, ["api": 200]),        // the previous week
            day(12, nil, tokens: 40),    // before breakdowns existed
        ]
        let r = ReportBuilder.report(history: history, days: 7, end: end, groupBy: .project, seriesGroups: 2, calendar: cal)
        XCTAssertEqual(r.total.tokens, 560)
        XCTAssertEqual(r.previous.tokens, 240)
        XCTAssertEqual(r.activeDays, 2)
        XCTAssertEqual(r.rows.map(\.name), ["api", "web", "cli", "docs"])
        XCTAssertEqual(r.rows.first?.previous.tokens, 200)
        XCTAssertEqual(r.rows.first?.share ?? 0, 400.0 / 560, accuracy: 0.0001)
        XCTAssertEqual(Set(r.series.map(\.group)), ["api", "web", ReportBuilder.other])
        XCTAssertEqual(Report.change(Double(r.total.tokens), Double(r.previous.tokens)) ?? 0, 560.0 / 240 - 1, accuracy: 0.0001)

        let longer = ReportBuilder.report(history: history, days: 14, end: end, groupBy: .project, calendar: cal)
        XCTAssertEqual(longer.rows.first { $0.name == ReportBuilder.unattributed }?.tokens, 40)
        // Day 12 has totals only, so this week's per-project changes are unknown...
        XCTAssertFalse(r.previousBrokenDown)
        // ...while a week later the week before is fully broken down.
        let next = ReportBuilder.report(history: history, days: 7, end: cal.date(byAdding: .day, value: 7, to: end)!,
                                        groupBy: .project, calendar: cal)
        XCTAssertTrue(next.previousBrokenDown)

        // By cost, a cheap-token, pricey project ranks first.
        var pricey = day(1, ["cheap": 1_000])
        pricey.projects?["pricey"] = DayUsage(tokens: 10, cost: 50)
        let byCost = ReportBuilder.report(history: [pricey], days: 7, end: end, groupBy: .project, rankByCost: true, calendar: cal)
        XCTAssertEqual(byCost.rows.first?.name, "pricey")
    }

    func testLastWeekStartsOnMonday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = try XCTUnwrap(DateParsing.iso("2026-10-28T15:00:00Z"))
        XCTAssertEqual(ReportBuilder.lastWeekStart(now: wednesday, calendar: cal), DateParsing.iso("2026-10-19T00:00:00Z"))
    }
}

final class GeminiTests: XCTestCase {
    func testSessionLogDedupesByMessageIDAndKeepsRewoundTokens() throws {
        var agg = GeminiLogParser.parse(try fixture("gemini_session.jsonl"))
        // g1 counted once though written three times; g2 counted though rewound afterwards.
        XCTAssertEqual(agg.totalTokens, 1_070 + 1_230)
        XCTAssertEqual(agg.models, ["gemini-3.1-pro"])
        XCTAssertEqual(agg.activity.filter { $0.a == .prompt }.count, 1, "a tool result is not a prompt")
        XCTAssertEqual(agg.activity.filter { $0.a == .tool }.count, 1)
        // Unpriced until Google's list prices are added.
        XCTAssertTrue(agg.entries.allSatisfy { $0.c == nil })

        // Parsing appended bytes again adds nothing new.
        let before = agg
        _ = GeminiLogParser.parse(try fixture("gemini_session.jsonl"), into: &agg)
        XCTAssertEqual(agg.totalTokens, before.totalTokens)
        XCTAssertEqual(agg.activity.count, before.activity.count)
    }

    func testProjectComesFromTheFolder() {
        let url = URL(fileURLWithPath: "/Users/x/.gemini/tmp/api-server/chats/session-2026-10-20T10-00-5f0c2a9e.jsonl")
        XCTAssertEqual(GeminiLogParser.project(for: url), "api-server")
        let sub = URL(fileURLWithPath: "/Users/x/.gemini/tmp/api-server/chats/5f0c2a9e/child.jsonl")
        // Subagent sessions sit one level deeper, under the parent session's id.
        XCTAssertEqual(GeminiLogParser.project(for: sub), "api-server")
    }

    func testQuotaBucketsBecomeOneWindowPerFamily() throws {
        let windows = GeminiProvider.windows(try fixtureJSON("gemini_quota.json"))
        XCTAssertEqual(windows.map(\.title), ["Pro", "Flash", "Flash Lite"])
        // The fuller of the two Pro buckets.
        XCTAssertEqual(windows[0].usedPercent, 60, accuracy: 0.001)
        XCTAssertEqual(windows[0].resetsAt, DateParsing.iso("2026-10-21T07:00:00Z"))
        XCTAssertEqual(windows[0].windowLength, 86_400)
        XCTAssertEqual(windows[1].usedPercent, 5, accuracy: 0.001)
        XCTAssertEqual(windows[2].usedPercent, 0)
    }

    func testAfterAgentCarriesTheReply() {
        let e = AgentEvent.from(
            hookInput: ["session_id": "s", "prompt": "hi", "prompt_response": "All done."],
            agent: "gemini", kind: .stop, environment: [:]
        )
        XCTAssertEqual(e.lastMessage, "All done.")
        let none = AgentEvent.from(hookInput: ["prompt_response": "[no response text]"], agent: "gemini", kind: .stop, environment: [:])
        XCTAssertNil(none.lastMessage)
    }

    func testTranscriptTailReadsTheLastGeminiReply() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chats = home.appendingPathComponent("tmp/api-server/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-2026-10-20T10-00-5f0c2a9e.jsonl")
        try fixture("gemini_session.jsonl").write(to: file)
        let found = try XCTUnwrap(TranscriptTail.locate(sessionID: "5f0c2a9e-1111-4c5e-9d21-aaaaaaaaaaaa", provider: .gemini, homes: [home]))
        XCTAssertEqual(found.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(TranscriptTail.lastReply(file: found).flatMap { ReplyExcerpt.make($0) }, "Done. Added the /health route and a test.")
    }

    func testHooksUseGeminiNamesMillisecondsAndKeepOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = #"{"security":{"auth":{"selectedType":"oauth-personal"}},"hooks":{"SessionEnd":[{"matcher":"exit","hooks":[{"name":"tokentracker","type":"command","command":"notify --source=gemini"}]}]}}"#
        try original.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let acct = Account(provider: .gemini, homePath: dir.path, label: "g")
        let exe = "/Applications/Agentilo.app/Contents/MacOS/Agentilo"

        try HookInstaller.install(for: acct, executable: exe, approvals: true, approvalTimeout: 60)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: true), .installed)
        let hooks = try XCTUnwrap(try HookInstaller.read(HookInstaller.configURL(for: acct)!)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"])
        let after = try XCTUnwrap((hooks["AfterAgent"] as? [[String: Any]])?.first)
        XCTAssertEqual(after["matcher"] as? String, "*")
        let hook = try XCTUnwrap((after["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["timeout"] as? Int, 5_000)
        XCTAssertEqual(hook["name"] as? String, "agentilo-stop")
        XCTAssertEqual(hook["command"] as? String, "'\(exe)' hook gemini stop # agentilo")
        XCTAssertEqual((hooks["SessionEnd"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(HookInstaller.geminiHooksEnabled(home: dir))

        try HookInstaller.uninstall(for: acct)
        let back = try HookInstaller.read(HookInstaller.configURL(for: acct)!)
        XCTAssertEqual(back as NSDictionary, try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary)
    }

    func testCredentialsAreReadOnlyAndExpiryIsMilliseconds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"access_token":"ya29.x","expiry_date":1784000000000,"refresh_token":"r"}"#
            .write(to: dir.appendingPathComponent("oauth_creds.json"), atomically: true, encoding: .utf8)
        try #"{"active":"me@example.com","old":[]}"#.write(to: dir.appendingPathComponent("google_accounts.json"), atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(GeminiCredentials.load(home: dir.path))
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_784_000_000))
        XCTAssertTrue(c.isExpired(now: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(GeminiCredentials.email(home: dir.path), "me@example.com")
        XCTAssertEqual(AccountDetector.defaultLabel(.gemini, dir.path), "me@example.com")
    }
}

final class ProxyTests: XCTestCase {
    func testDirectDisablesProxies() {
        let c = SessionFactory.configuration(for: EffectiveProxy(config: ProxyConfig(kind: .direct)))
        XCTAssertEqual(c.connectionProxyDictionary?[kCFNetworkProxiesHTTPSEnable as String] as? Bool, false)
        XCTAssertTrue(c.proxyConfigurations.isEmpty)
    }

    func testServerKindsInstallProxyConfiguration() {
        for kind in [ProxyKind.http, .https, .socks5] {
            let cfg = ProxyConfig(kind: kind, host: "127.0.0.1", port: 9000, username: "u")
            let c = SessionFactory.configuration(for: EffectiveProxy(config: cfg, password: "p"))
            XCTAssertEqual(c.proxyConfigurations.count, 1, "\(kind)")
        }
    }

    func testValidation() {
        XCTAssertFalse(ProxyConfig(kind: .socks5, host: "", port: 1080).isValid)
        XCTAssertFalse(ProxyConfig(kind: .http, host: "h", port: 0).isValid)
        XCTAssertTrue(ProxyConfig(kind: .system).isValid)
    }

    func testProviderOverrideResolution() {
        var s = AppSettings()
        s.globalProxy = ProxyConfig(kind: .socks5, host: "10.0.0.1", port: 1080)
        s.providerProxies[Provider.codex.rawValue] = ProviderProxy(useGlobal: false, config: ProxyConfig(kind: .direct))
        XCTAssertEqual(s.effectiveProxy(for: .claude).config.kind, .socks5)
        XCTAssertEqual(s.effectiveProxy(for: .codex).config.kind, .direct)
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{\"refreshInterval\": 300}".utf8))
        XCTAssertEqual(s.refreshInterval, 300)
        XCTAssertTrue(s.showTokenStats)
        XCTAssertEqual(s.globalProxy.kind, .system)
        XCTAssertFalse(s.quietSchedule.enabled)
        XCTAssertTrue(s.quietAllowUrgent)
        XCTAssertNil(s.snoozeUntil)
        XCTAssertFalse(s.quietManual)
        XCTAssertTrue(s.agentDoneSummary)
        XCTAssertTrue(s.pillShowsAgents)
        XCTAssertTrue(s.accountSuggestions)
        XCTAssertEqual(s.preferredTerminal, .none)
        XCTAssertTrue(s.weeklySummary)
        // A terminal this build does not know falls back instead of failing the whole file.
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data("{\"preferredTerminal\": \"warp\"}".utf8))
        XCTAssertEqual(odd.preferredTerminal, .none)
    }
}

final class QuietModeTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-10-26 is a Monday (weekday 2).
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testOvernightScheduleWrapsPastMidnight() {
        let s = QuietSchedule(enabled: true, start: 22 * 60, end: 8 * 60)
        XCTAssertTrue(s.contains(at(26, 23), calendar: cal))
        XCTAssertTrue(s.contains(at(27, 7, 59), calendar: cal))
        XCTAssertFalse(s.contains(at(27, 8), calendar: cal))
        XCTAssertFalse(s.contains(at(26, 21, 59), calendar: cal))
    }

    func testDaysCountFromTheEveningTheyStart() {
        // Weeknights only: Sunday–Thursday evenings (1...5).
        let s = QuietSchedule(enabled: true, start: 22 * 60, end: 8 * 60, days: [1, 2, 3, 4, 5])
        XCTAssertTrue(s.contains(at(29, 23), calendar: cal))   // Thursday evening
        XCTAssertFalse(s.contains(at(30, 23), calendar: cal))  // Friday evening
        XCTAssertTrue(s.contains(at(30, 7), calendar: cal))    // Friday 07:00 belongs to Thursday night
        XCTAssertFalse(s.contains(at(31, 7), calendar: cal))   // Saturday 07:00 belongs to Friday night
    }

    func testSameDayScheduleAndDisabled() {
        let lunch = QuietSchedule(enabled: true, start: 12 * 60, end: 13 * 60)
        XCTAssertTrue(lunch.contains(at(26, 12, 30), calendar: cal))
        XCTAssertFalse(lunch.contains(at(26, 13), calendar: cal))
        XCTAssertFalse(QuietSchedule(enabled: false, start: 0, end: 0).contains(at(26, 12), calendar: cal))
        XCTAssertTrue(QuietSchedule(enabled: true, start: 0, end: 0).contains(at(26, 12), calendar: cal))
    }

    func testQuietCommandArguments() {
        XCTAssertEqual(QuietRequest(argument: "on"), QuietRequest(action: .on))
        XCTAssertEqual(QuietRequest(argument: "OFF"), QuietRequest(action: .off))
        XCTAssertEqual(QuietRequest(argument: "45m"), QuietRequest(action: .snooze, minutes: 45))
        XCTAssertEqual(QuietRequest(argument: "2h"), QuietRequest(action: .snooze, minutes: 120))
        XCTAssertEqual(QuietRequest(argument: "30"), QuietRequest(action: .snooze, minutes: 30))
        XCTAssertNil(QuietRequest(argument: "soon"))
        XCTAssertNil(QuietRequest(argument: "0m"))

        var s = AppSettings()
        let now = at(26, 12)
        QuietRequest(action: .snooze, minutes: 90).apply(to: &s, now: now)
        XCTAssertEqual(s.snoozeUntil, now.addingTimeInterval(5400))
        QuietRequest(action: .on).apply(to: &s, now: now)
        XCTAssertTrue(s.quietManual)
        QuietRequest(action: .off).apply(to: &s, now: now)
        XCTAssertFalse(s.quietManual)
        XCTAssertNil(s.snoozeUntil)
    }

    func testReasonPrefersManualThenSnoozeThenSchedule() {
        let now = at(26, 12)
        let off = QuietSchedule()
        XCTAssertEqual(QuietMode.reason(now: now, schedule: off, snoozeUntil: nil, manual: true, calendar: cal), .manual)
        let later = now.addingTimeInterval(3600)
        XCTAssertEqual(QuietMode.reason(now: now, schedule: off, snoozeUntil: later, manual: false, calendar: cal), .snoozed(until: later))
        XCTAssertNil(QuietMode.reason(now: now, schedule: off, snoozeUntil: now.addingTimeInterval(-1), manual: false, calendar: cal))
        let allDay = QuietSchedule(enabled: true, start: 0, end: 0)
        XCTAssertEqual(QuietMode.reason(now: now, schedule: allDay, snoozeUntil: nil, manual: false, calendar: cal), .schedule)
    }
}

final class OfflineFallbackTests: XCTestCase {
    func testCodexLogCarriesRateLimits() throws {
        let agg = CodexLogParser.parse(try fixture("codex_session.jsonl"))
        let sample = try XCTUnwrap(agg.rateLimits)
        let snap = LocalUsage.codex(sample, base: nil)
        XCTAssertEqual(snap.source, .localLog)
        XCTAssertEqual(snap.windows.map(\.title), ["Session", "Weekly"])
        XCTAssertEqual(snap.windows.map(\.usedPercent), [12, 61])
        XCTAssertEqual(snap.windows[1].windowLength, 7 * 86_400)
        XCTAssertEqual(snap.plan, "Pro Lite")
    }

    func testRollOverResetsExpiredWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snap = UsageSnapshot(windows: [
            UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 80,
                        resetsAt: now.addingTimeInterval(-60), windowLength: 18_000),
            UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 50,
                        resetsAt: now.addingTimeInterval(-60), windowLength: 604_800),
            UsageWindow(id: "x", kind: .weekly, title: "Weekly", usedPercent: 30,
                        resetsAt: now.addingTimeInterval(60), windowLength: 604_800),
        ])
        let r = snap.rolledOver(now: now)
        XCTAssertEqual(r.windows.map(\.usedPercent), [0, 0, 30])
        XCTAssertNil(r.windows[0].resetsAt)
        XCTAssertEqual(r.windows[1].resetsAt, now.addingTimeInterval(604_800 - 60))
    }

    func testClaudeEstimateAdvancesByLoggedTokens() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projects = tmp.appendingPathComponent("home/projects/p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        func line(_ id: String, _ at: Date, input: Int) -> String {
            #"{"type":"assistant","requestId":"r\#(id)","timestamp":"\#(iso.string(from: at))","message":{"id":"m\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
        }
        let fetchedAt = now.addingTimeInterval(-1_800)
        let log = [
            line("1", now.addingTimeInterval(-3_600), input: 100_000), // before the snapshot
            line("2", now.addingTimeInterval(-600), input: 50_000),    // after the snapshot
        ].joined(separator: "\n") + "\n"
        try log.write(to: projects.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let account = Account(provider: .claude, homePath: tmp.appendingPathComponent("home").path, label: "t")
        let engine = StatsEngine(cacheURL: tmp.appendingPathComponent("cache.json"))
        _ = engine.compute(accounts: [account], now: now)

        let snap = UsageSnapshot(windows: [
            UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 10,
                        resetsAt: now.addingTimeInterval(3_600), windowLength: 18_000),
        ], fetchedAt: fetchedAt)
        let cal = LocalUsage.calibrate(snap, account: account, engine: engine, previous: [:])
        XCTAssertEqual(try XCTUnwrap(cal["session"]), 10.0 / 100_000, accuracy: 1e-12)

        let est = LocalUsage.estimate(StoredUsage(snapshot: snap, calibration: cal), account: account, engine: engine, now: now)
        XCTAssertEqual(est.source, .estimated)
        XCTAssertEqual(est.windows[0].usedPercent, 15, accuracy: 0.001)
    }

    func testDisplayModeRemaining() {
        XCTAssertEqual(UsageDisplay.remaining.value(61), 39)
        XCTAssertEqual(UsageDisplay.remaining.value(120), 0)
        XCTAssertEqual(UsageDisplay.used.value(61), 61)
    }
}

final class AlertEngineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let account = Account(provider: .claude, homePath: "~/.claude", label: "me")

    private func snap(_ used: Double, reset: TimeInterval = 3_600) -> UsageSnapshot {
        UsageSnapshot(windows: [
            UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: used,
                        resetsAt: now.addingTimeInterval(reset), windowLength: 18_000),
        ])
    }

    private func run(_ old: UsageSnapshot?, _ new: UsageSnapshot, _ fired: inout [String: Date]) -> [LimitAlert.Kind] {
        AlertEngine.evaluate(previous: old, current: new, account: account, thresholds: [75, 90, 100],
                             resetAlerts: true, fired: &fired, now: now).map(\.kind)
    }

    func testFiresHighestCrossedThresholdOnce() {
        var fired: [String: Date] = [:]
        XCTAssertEqual(run(snap(50), snap(70), &fired), [])
        XCTAssertEqual(run(snap(70), snap(92), &fired), [.threshold(90)])
        // Same period: no repeat, and 75 is not fired after 90.
        XCTAssertEqual(run(snap(92), snap(93), &fired), [])
        XCTAssertEqual(run(snap(93), snap(100), &fired), [.limitReached])
    }

    func testResetFiresAndClearsPeriod() {
        var fired: [String: Date] = [:]
        _ = run(nil, snap(95), &fired)
        XCTAssertEqual(run(snap(95), snap(1, reset: 18_000), &fired), [.reset])
        XCTAssertEqual(run(snap(1, reset: 18_000), snap(80, reset: 18_000), &fired), [.threshold(75)])
    }

    func testResetJitterKeepsKey() {
        var fired: [String: Date] = [:]
        _ = run(nil, snap(80), &fired)
        XCTAssertEqual(run(snap(80), snap(81, reset: 3_600.4), &fired), [])
    }
}

final class LocalAPITests: XCTestCase {
    private func parse(_ s: String) -> HTTPRequest? {
        if case .complete(let r) = HTTPRequest.parse(Data(s.utf8)) { return r }
        return nil
    }

    func testParsesRequestWithBodyAndQuery() throws {
        let r = try XCTUnwrap(parse("POST /v1/events?x=1 HTTP/1.1\r\nHost: 127.0.0.1:6737\r\nContent-Length: 4\r\n\r\nabcd"))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/events")
        XCTAssertEqual(r.query["x"], "1")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "abcd")
        XCTAssertTrue(r.isTrustedLocal(port: 6737))
    }

    func testIncompleteUntilBodyArrives() {
        guard case .incomplete = HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) else {
            return XCTFail()
        }
        guard case .incomplete = HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) else { return XCTFail() }
    }

    func testRefusesBrowserAndForeignHost() throws {
        let browser = try XCTUnwrap(parse("GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:6737\r\nOrigin: https://evil.example\r\n\r\n"))
        XCTAssertFalse(browser.isTrustedLocal(port: 6737))
        let rebound = try XCTUnwrap(parse("GET /v1/limits HTTP/1.1\r\nHost: evil.example:6737\r\n\r\n"))
        XCTAssertFalse(rebound.isTrustedLocal(port: 6737))
    }

    func testPayloadRedactsLabelsAndFormatsShortLine() {
        let a = Account(provider: .claude, homePath: "~/.claude", label: "me@example.com")
        let b = Account(provider: .codex, homePath: "~/.codex", label: "work@example.com")
        let snap = UsageSnapshot(windows: [
            UsageWindow(id: "s", kind: .session, title: "Session", usedPercent: 16.04, resetsAt: nil, windowLength: nil),
            UsageWindow(id: "w", kind: .weekly, title: "Weekly", usedPercent: 100, resetsAt: nil, windowLength: nil),
        ])
        let p = LimitsPayload.build(accounts: [a, b], snapshots: [a.id: snap], includeLabels: false, origin: "app")
        XCTAssertEqual(p.accounts.map(\.label), ["Claude 1", "Codex 1"])
        XCTAssertEqual(p.accounts[0].windows[0].usedPercent, 16)
        XCTAssertEqual(p.accounts[0].windows[1].pace, "limitReached")
        XCTAssertEqual(p.shortLine(), "Claude S 16% W 100%!")
        let labeled = LimitsPayload.build(accounts: [a], snapshots: [:], includeLabels: true, origin: "app")
        XCTAssertEqual(labeled.accounts[0].label, "me@example.com")
    }

    func testServerAnswersOverLoopback() async throws {
        let port: UInt16 = 46_737
        let server = LocalServer(port: port) { req in .json(["path": req.path]) }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let (data, resp) = try await URLSession(configuration: config).data(from: URL(string: "http://127.0.0.1:\(port)/v1/x")!)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: data)["path"], "/v1/x")

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/x")!)
        req.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, denied) = try await URLSession(configuration: config).data(for: req)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
    }
}

final class AgentSessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    let pane = HerdrLocation(pane: "w:p1", tab: "w:t1", workspace: "w")

    private func event(_ kind: AgentEventKind, at: TimeInterval, herdr: HerdrLocation? = nil, type: String? = nil) -> AgentEvent {
        AgentEvent(agent: "claude", kind: kind, sessionID: "s1", cwd: "/p/web", tool: kind == .preTool ? "Bash" : nil,
                   notificationType: type, herdr: herdr, at: t0.addingTimeInterval(at))
    }

    private func herdr(_ status: HerdrAgent.Status, sessionID: String? = "s1") -> HerdrAgent {
        HerdrAgent(agent: "claude", status: status, sessionID: sessionID, cwd: "/p/web", title: "task", focused: false, location: pane)
    }

    func testHookLifecycle() {
        var store = AgentSessionStore()
        store.apply(event(.sessionStart, at: 0))
        store.apply(event(.prompt, at: 1))
        store.apply(event(.preTool, at: 2))
        let s = store.sessions["claude:s1"]!
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.tool, "Bash")
        XCTAssertEqual(s.project, "web")

        let ask = store.apply(event(.notification, at: 3, type: "permission_prompt"))
        XCTAssertEqual(ask.first?.to, .waitingPermission)
        XCTAssertEqual(store.attentionCount, 1)
        let done = store.apply(event(.stop, at: 60))
        XCTAssertEqual(done.first?.to, .done)
        store.apply(event(.sessionEnd, at: 61))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testHerdrDrivesStateAndAdoptsHookSession() {
        var store = AgentSessionStore()
        store.apply(event(.prompt, at: 0))
        XCTAssertNotNil(store.sessions["claude:s1"])
        // herdr lists the same session id in a pane: one session, keyed by the pane.
        store.applyHerdr([herdr(.working)], now: t0.addingTimeInterval(10))
        XCTAssertEqual(Array(store.sessions.keys), ["herdr:w:p1"])
        XCTAssertEqual(store.sessions["herdr:w:p1"]?.title, "task")

        let blocked = store.applyHerdr([herdr(.blocked)], now: t0.addingTimeInterval(20))
        XCTAssertEqual(blocked.first?.to, .waitingPermission)
        let idle = store.applyHerdr([herdr(.idle)], now: t0.addingTimeInterval(30))
        XCTAssertEqual(idle.first?.to, .done)

        // Pane gone: session gone.
        store.applyHerdr([], now: t0.addingTimeInterval(60))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testFreshHookWinsOverHerdr() {
        var store = AgentSessionStore()
        store.applyHerdr([herdr(.working)], now: t0)
        store.apply(event(.notification, at: 1, herdr: pane, type: "idle_prompt"))
        // herdr still reads the screen as working a moment later; the hook knows better.
        store.applyHerdr([herdr(.working)], now: t0.addingTimeInterval(2))
        XCTAssertEqual(store.sessions["herdr:w:p1"]?.state, .waitingInput)
    }

    func testFirstSightingIsNotATransitionToDone() {
        var store = AgentSessionStore()
        let t = store.applyHerdr([herdr(.idle)], now: t0)
        XCTAssertNil(t.first?.from)
        XCTAssertEqual(store.sessions.values.first?.state, .idle)
    }

    func testParsesHerdrList() throws {
        let agents = try XCTUnwrap(HerdrSource.parse(try fixture("herdr_agents.json")))
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents[0].status, .idle)
        XCTAssertEqual(agents[0].sessionID, "19eaaa41-a3ee-4050-911f-eaf3060bceaa")
        XCTAssertEqual(agents[0].title, "ui-polish")
        XCTAssertEqual(agents[1].status, .blocked)
        XCTAssertNil(agents[1].title)
        XCTAssertTrue(agents[1].focused)
        XCTAssertEqual(agents[1].location, HerdrLocation(pane: "wP:p4F", tab: "wP:t2A", workspace: "wP"))
    }

    func testEventFromHookInput() {
        let e = AgentEvent.from(
            hookInput: ["session_id": "abc", "cwd": "/x/api", "tool_name": "Bash",
                        "tool_input": ["command": "npm test\necho done"]],
            agent: "claude", kind: .preTool, environment: ["HERDR_PANE_ID": "w:p9", "HERDR_TAB_ID": "w:t1"]
        )
        XCTAssertEqual(e.detail, "npm test")
        XCTAssertEqual(e.herdr?.pane, "w:p9")
        XCTAssertEqual(AgentEvent.toolSummary(tool: "Edit", input: ["file_path": "/a/b/AppState.swift"]), "AppState.swift")
    }
}

final class TurnSummaryTests: XCTestCase {
    func testClaudeTranscriptGivesTheLastMessageText() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude_reply", withExtension: "jsonl", subdirectory: "Fixtures"))
        let reply = try XCTUnwrap(TranscriptTail.lastReply(file: url))
        XCTAssertTrue(reply.hasPrefix("## Fixed"))
        XCTAssertTrue(reply.hasSuffix("Run `make test` to confirm."))
        XCTAssertEqual(
            ReplyExcerpt.make(reply),
            "Fixed. The build passes now. I removed the stale build/ cache in Makefile. Run make test to confirm."
        )
    }

    func testCodexTranscriptPrefersTaskComplete() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codex_reply", withExtension: "jsonl", subdirectory: "Fixtures"))
        XCTAssertEqual(TranscriptTail.lastReply(file: url), "Done: added the /health route and a test.")
    }

    func testExcerptDropsCodeAndCaps() {
        let text = "Here is the fix:\n```swift\nlet x = 1\n```\n- first\n- second\n" + String(repeating: "word ", count: 200)
        let e = ReplyExcerpt.make(text, limit: 60)!
        XCTAssertTrue(e.hasPrefix("Here is the fix: first second word"))
        XCTAssertFalse(e.contains("let x"))
        XCTAssertEqual(e.count, 60)
        XCTAssertNil(ReplyExcerpt.make("```\ncode only\n```"))
    }

    func testShortTurnsShowSeconds() {
        XCTAssertEqual(Formatters.duration(22), "22s")
        XCTAssertEqual(Formatters.duration(240), "4m")
        XCTAssertEqual(Formatters.duration(3_900), "1h 5m")
    }

    func testStopHookCarriesReplyAndTurnCounters() {
        var store = AgentSessionStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        store.apply(AgentEvent(agent: "claude", kind: .prompt, sessionID: "s", at: t0))
        store.apply(AgentEvent(agent: "claude", kind: .preTool, sessionID: "s", tool: "Bash", at: t0 + 5))
        store.apply(AgentEvent(agent: "claude", kind: .preTool, sessionID: "s", tool: "Edit", at: t0 + 9))
        store.apply(AgentEvent(agent: "claude", kind: .permission, sessionID: "s", at: t0 + 10))
        store.apply(AgentEvent(agent: "claude", kind: .postTool, sessionID: "s", at: t0 + 20))
        var s = store.sessions["claude:s"]!
        XCTAssertEqual(s.turnStartedAt, t0, "a permission wait keeps the turn")
        XCTAssertEqual(s.toolCalls, 2)
        store.apply(AgentEvent(agent: "claude", kind: .stop, sessionID: "s", lastMessage: "**Done.** All green.", at: t0 + 30))
        s = store.sessions["claude:s"]!
        XCTAssertEqual(s.lastReply, "Done. All green.")
        store.apply(AgentEvent(agent: "claude", kind: .prompt, sessionID: "s", at: t0 + 60))
        s = store.sessions["claude:s"]!
        XCTAssertEqual(s.turnStartedAt, t0 + 60)
        XCTAssertEqual(s.toolCalls, 0)
        XCTAssertNil(s.lastReply)
    }

    func testHookInputReadsReplyFieldsOfEitherAgent() {
        let claude = AgentEvent.from(
            hookInput: ["session_id": "a", "last_assistant_message": "All set.", "transcript_path": "/t/a.jsonl"],
            agent: "claude", kind: .stop, environment: [:]
        )
        XCTAssertEqual(claude.lastMessage, "All set.")
        XCTAssertEqual(claude.transcriptPath, "/t/a.jsonl")
        let codex = AgentEvent.from(hookInput: ["last-assistant-message": "Done."], agent: "codex", kind: .stop, environment: [:])
        XCTAssertEqual(codex.lastMessage, "Done.")
        XCTAssertNil(AgentEvent.from(hookInput: ["last_assistant_message": ""], agent: "claude", kind: .stop, environment: [:]).lastMessage)
    }
}

final class HookInstallerTests: XCTestCase {
    let exe = "/Applications/Agentilo.app/Contents/MacOS/Agentilo"

    private func tempHome(_ settings: String?) throws -> Account {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let settings { try settings.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8) }
        return Account(provider: .claude, homePath: dir.path, label: "t")
    }

    func testInstallKeepsOtherHooksAndRemovesCleanly() throws {
        let original = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"atuin hook claude"}]}]}}"#
        let acct = try tempHome(original)
        let url = HookInstaller.configURL(for: acct)!
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: false), .notInstalled)

        try HookInstaller.install(for: acct, executable: exe, approvals: false, approvalTimeout: 60)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: false), .installed)
        // Installing twice does not duplicate.
        try HookInstaller.install(for: acct, executable: exe, approvals: false, approvalTimeout: 60)
        let root = try HookInstaller.read(url)
        XCTAssertEqual(root["model"] as? String, "opus")
        let pre = try XCTUnwrap((root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(HookInstaller.commands(in: root).count, HookInstaller.events(for: .claude, approvals: false).count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".agentilo-bak"))

        // Another copy of the app, or approvals turned on: outdated.
        XCTAssertEqual(HookInstaller.status(for: acct, executable: "/tmp/Other", approvals: false), .outdated)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: true), .outdated)

        try HookInstaller.uninstall(for: acct)
        let after = try HookInstaller.read(url)
        let expected = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! NSDictionary
        XCTAssertEqual(after as NSDictionary, expected)
    }

    func testInstallIntoMissingFileAndRemoveEmptiesHooks() throws {
        let acct = try tempHome(nil)
        try HookInstaller.install(for: acct, executable: exe, approvals: true, approvalTimeout: 60)
        let root = try HookInstaller.read(HookInstaller.configURL(for: acct)!)
        let perm = try XCTUnwrap((root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        let hook = try XCTUnwrap((perm.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["timeout"] as? Int, 70)
        XCTAssertEqual(hook["command"] as? String, "'\(exe)' hook claude permission # agentilo")
        try HookInstaller.uninstall(for: acct)
        XCTAssertTrue(try HookInstaller.read(HookInstaller.configURL(for: acct)!).isEmpty)
    }

    func testReinstallReplacesHooksFromBeforeTheRename() throws {
        let old = "'/Applications/AgentLimits.app/Contents/MacOS/AgentLimits' hook claude stop # agentlimits"
        let acct = try tempHome(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)","timeout":5}]}]}}"#)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: false), .outdated)
        try HookInstaller.install(for: acct, executable: exe, approvals: false, approvalTimeout: 60)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: exe, approvals: false), .installed)
        let root = try HookInstaller.read(HookInstaller.configURL(for: acct)!)
        XCTAssertFalse(HookInstaller.commands(in: root).contains(old))
    }
}

final class ApprovalTests: XCTestCase {
    private let hookInput: [String: Any] = [
        "session_id": "s9", "cwd": "/p/api", "tool_name": "Bash",
        "tool_input": ["command": "rm -rf build\nmake"],
        "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                    "rules": [["toolName": "Bash", "ruleContent": "make:*"]]]],
    ]

    private func output(_ d: ApprovalDecision, _ r: ApprovalRequest) throws -> [String: Any]? {
        guard let data = ApprovalResponse(decision: d).hookOutput(for: r) else { return nil }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return specific["decision"] as? [String: Any]
    }

    func testRequestFromHookInput() {
        let r = ApprovalRequest.from(hookInput: hookInput, agent: "claude", environment: [:])
        XCTAssertEqual(r.input, "rm -rf build\nmake")
        XCTAssertEqual(r.event.kind, .permission)
        XCTAssertEqual(r.event.detail, "rm -rf build")
        XCTAssertTrue(r.canAlwaysAllow)
        XCTAssertFalse(ApprovalRequest(event: r.event, input: nil, suggestions: "[]").canAlwaysAllow)
    }

    func testDecisionsEncodeAsHookOutput() throws {
        let r = ApprovalRequest.from(hookInput: hookInput, agent: "claude", environment: [:])
        XCTAssertNil(try output(.none, r))
        XCTAssertEqual(try output(.allow, r)?["behavior"] as? String, "allow")
        XCTAssertNil(try output(.allow, r)?["updatedPermissions"])
        let deny = try XCTUnwrap(try output(.deny, r))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertNotNil(deny["message"])
        let always = try XCTUnwrap(try output(.allowAlways, r))
        XCTAssertEqual((always["updatedPermissions"] as? [[String: Any]])?.first?["type"] as? String, "addRules")
    }

    func testRequestRoundTripsThroughAPIJSON() throws {
        let r = ApprovalRequest.from(hookInput: hookInput, agent: "claude", environment: ["HERDR_PANE_ID": "w:p1"])
        var back = try APIJSON.decoder.decode(ApprovalRequest.self, from: APIJSON.encoder.encode(r))
        // ISO 8601 keeps whole seconds.
        XCTAssertEqual(back.event.at.timeIntervalSince1970, r.event.at.timeIntervalSince1970, accuracy: 1)
        back.event.at = r.event.at
        XCTAssertEqual(back, r)
    }

    func testTimeoutChangeMakesHooksOutdated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let acct = Account(provider: .claude, homePath: dir.path, label: "t")
        try HookInstaller.install(for: acct, executable: "/x/Agentilo", approvals: true, approvalTimeout: 30)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: "/x/Agentilo", approvals: true, approvalTimeout: 30), .installed)
        XCTAssertEqual(HookInstaller.status(for: acct, executable: "/x/Agentilo", approvals: true, approvalTimeout: 60), .outdated)
    }
}

final class ActivityStatsTests: XCTestCase {
    func testPricing() throws {
        XCTAssertEqual(Pricing.rate(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(Pricing.rate(for: "claude-opus-5-20260101")?.input, 5)
        XCTAssertEqual(Pricing.rate(for: "claude-sonnet-4-6")?.output, 15)
        XCTAssertEqual(Pricing.rate(for: "gpt-6.1-sol")?.cacheRead, 0.10)
        XCTAssertNil(Pricing.rate(for: "gpt-6-luna"))
        // 1M input + 1M output + 1M cache write + 1M cache read on Opus 5.5: 4 + 20 + 5 + 0.2.
        let c = try XCTUnwrap(Pricing.cost(model: "claude-opus-5-5", input: 1e6, output: 1e6, cacheWrite: 1e6, cacheRead: 1e6))
        XCTAssertEqual(c, 29.2, accuracy: 1e-9)
    }

    func testClaudeCountsPromptsAndSplitToolUses() {
        let log = """
        {"type":"user","promptId":"p1","timestamp":"2026-10-20T10:00:00Z","cwd":"/x/web","message":{"role":"user","content":"fix it"}}
        {"type":"user","timestamp":"2026-10-20T10:00:00Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"assistant","requestId":"r1","timestamp":"2026-10-20T10:00:01Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Bash"}],"usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"assistant","requestId":"r1","timestamp":"2026-10-20T10:00:01Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t2","name":"Read"}],"usage":{"input_tokens":1000000,"output_tokens":0}}}
        {"type":"user","timestamp":"2026-10-20T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}

        """
        let agg = ClaudeLogParser.parse(Data(log.utf8))
        XCTAssertEqual(agg.activity.filter { $0.a == .prompt }.count, 1)
        XCTAssertEqual(agg.activity.filter { $0.a == .tool }.count, 2)
        XCTAssertEqual(agg.entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(agg.entries.first?.c), 4, accuracy: 1e-9)
    }

    func testCodexCountsTurnsAndCalls() {
        let log = """
        {"timestamp":"2026-10-20T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-20T10:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1"}}
        {"timestamp":"2026-10-20T10:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"c2"}}
        {"timestamp":"2026-10-20T10:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c2"}}

        """
        let agg = CodexLogParser.parse(Data(log.utf8))
        XCTAssertEqual(agg.activity.map(\.a), [.prompt, .tool, .tool])
    }

    func testStreaksAndHistoryMerge() throws {
        let cal = Calendar.current
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12)))
        func key(_ ago: Int) -> Int32 { DayKey.int(cal.date(byAdding: .day, value: -ago, to: now)!) }
        func rec(_ ago: Int, _ tokens: Int) -> DayRecord { DayRecord(day: key(ago), tokens: tokens) }

        // Old day outside the log lookback survives; a scanned day is replaced by the scan.
        let old: [Int32: DayRecord] = [key(100): rec(100, 5), key(2): rec(2, 999)]
        let merged = StatsEngine.mergeHistory(old, recent: [rec(1, 10), rec(2, 20)], now: now)
        XCTAssertEqual(merged[key(100)]?.tokens, 5)
        XCTAssertEqual(merged[key(2)]?.tokens, 20)

        // Today empty, the three days before active, a gap, then a run of four.
        var h: [Int32: DayRecord] = [:]
        for ago in [1, 2, 3, 5, 6, 7, 8] { h[key(ago)] = rec(ago, 1) }
        var stats = TokenStats()
        StatsEngine.applyHistory(h, to: &stats, now: now)
        XCTAssertEqual(stats.history.count, StatsEngine.historyDays)
        XCTAssertEqual(stats.history.last?.day, key(0))
        XCTAssertEqual(stats.currentStreak, 3)
        XCTAssertEqual(stats.longestStreak, 4)
    }
}

final class AccountAdvisorTests: XCTestCase {
    private func acct(_ label: String, _ provider: Provider = .claude, home: String) -> Account {
        Account(provider: provider, homePath: home, label: label)
    }

    private func snap(_ used: Double...) -> UsageSnapshot {
        UsageSnapshot(windows: used.enumerated().map {
            UsageWindow(id: "w\($0.offset)", kind: .weekly, title: "W", usedPercent: $0.element, resetsAt: nil, windowLength: nil)
        })
    }

    func testSuggestsTheEmptiestSibling() {
        let main = acct("Main", home: "~/.claude"), work = acct("Work", home: "~/.claude_multi/work"),
            side = acct("Side", home: "~/.claude_multi/side")
        let s = AccountAdvisor.suggest(
            accounts: [main, work, side],
            snapshots: [main.id: snap(40, 88), work.id: snap(12), side.id: snap(30, 50)]
        )
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.from.label, "Main")
        XCTAssertEqual(s.first?.to.label, "Work")
        XCTAssertEqual(s.first?.reason, "Work has 88% left")
        XCTAssertEqual(s.first?.command, "CLAUDE_CONFIG_DIR=~/.claude_multi/work claude")
    }

    func testNeedsPressureAndAGap() {
        let a = acct("A", home: "~/.claude"), b = acct("B", home: "~/.claude_b")
        // Not busy enough yet.
        XCTAssertTrue(AccountAdvisor.suggest(accounts: [a, b], snapshots: [a.id: snap(80), b.id: snap(0)]).isEmpty)
        // Busy, but the other one is nearly as full.
        XCTAssertTrue(AccountAdvisor.suggest(accounts: [a, b], snapshots: [a.id: snap(95), b.id: snap(70)]).isEmpty)
        // No sibling, or a sibling without numbers.
        XCTAssertTrue(AccountAdvisor.suggest(accounts: [a], snapshots: [a.id: snap(99)]).isEmpty)
        XCTAssertTrue(AccountAdvisor.suggest(accounts: [a, b], snapshots: [a.id: snap(99)]).isEmpty)
    }

    func testStaysWithinAProvider() {
        let claude = acct("C", home: "~/.claude"), codex = acct("X", .codex, home: "~/.codex_work")
        XCTAssertTrue(AccountAdvisor.suggest(accounts: [claude, codex], snapshots: [claude.id: snap(99), codex.id: snap(0)]).isEmpty)
        XCTAssertEqual(AccountAdvisor.command(for: codex), "CODEX_HOME=~/.codex_work codex")
        XCTAssertEqual(AccountAdvisor.command(for: acct("D", .codex, home: "~/.codex")), "codex")
        XCTAssertNil(AccountAdvisor.command(for: acct("Cur", .cursor, home: "/tmp/cursor")))
        XCTAssertEqual(AccountAdvisor.shellPath("/Volumes/My Disk/.claude"), "'/Volumes/My Disk/.claude'")
    }
}
