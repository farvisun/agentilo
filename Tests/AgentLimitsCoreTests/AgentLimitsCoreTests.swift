@testable import AgentLimitsCore
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
