import Foundation

public enum UsageDisplay: String, Codable, CaseIterable, Sendable, Identifiable {
    case used
    case remaining

    public var id: String { rawValue }
    public var displayName: String { self == .used ? "Used" : "Remaining" }

    /// Percentage to show for a window's used percentage.
    public func value(_ usedPercent: Double) -> Double {
        self == .used ? usedPercent : max(0, 100 - usedPercent)
    }
}

/// What the collapsed pill shows.
public enum PillMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The single account closest to its limit.
    case mostCritical
    /// The most critical account of each provider, one per wing.
    case perProvider
    /// One chosen account.
    case pinned

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mostCritical: "Most critical account"
        case .perProvider: "One per provider (side by side)"
        case .pinned: "Pinned account"
        }
    }
}

/// Which limit window the collapsed pill shows for an account.
public enum PillWindow: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whichever window is closest to its limit.
    case mostCritical
    case session
    case weekly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mostCritical: "Most critical"
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

/// How the collapsed pill draws the percentage left of the notch.
public enum PillStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case ring
    case number
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ring: "Circle"
        case .number: "Number"
        case .both: "Both"
        }
    }

    public var showsRing: Bool { self != .number }
    public var showsNumber: Bool { self != .ring }
}

/// What opens the expanded notch.
public enum ExpandTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    case hover
    case click

    public var id: String { rawValue }
    public var displayName: String { self == .hover ? "Hover" : "Click" }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var accounts: [Account] = []
    /// Seconds between limit refreshes.
    public var refreshInterval: Double = 120
    public var globalProxy = ProxyConfig()
    /// Keyed by `Provider.rawValue`.
    public var providerProxies: [String: ProviderProxy] = [:]
    public var showTokenStats = true
    public var launchAtLogin = false
    public var displayMode = UsageDisplay.used
    public var pillMode = PillMode.mostCritical
    public var pinnedAccount: UUID?
    public var expandTrigger = ExpandTrigger.hover
    public var pillWindow = PillWindow.mostCritical
    public var pillStyle = PillStyle.both
    public var alertsEnabled = true
    /// Usage percentages that drop an alert out of the notch; 100 means "limit reached".
    public var alertThresholds = [75, 90, 100]
    public var resetAlerts = true
    public var alertSound = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? d.accounts
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? d.refreshInterval
        globalProxy = try c.decodeIfPresent(ProxyConfig.self, forKey: .globalProxy) ?? d.globalProxy
        providerProxies = try c.decodeIfPresent([String: ProviderProxy].self, forKey: .providerProxies) ?? d.providerProxies
        showTokenStats = try c.decodeIfPresent(Bool.self, forKey: .showTokenStats) ?? d.showTokenStats
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        displayMode = try c.decodeIfPresent(UsageDisplay.self, forKey: .displayMode) ?? d.displayMode
        pillMode = try c.decodeIfPresent(PillMode.self, forKey: .pillMode) ?? d.pillMode
        pinnedAccount = try c.decodeIfPresent(UUID.self, forKey: .pinnedAccount)
        expandTrigger = try c.decodeIfPresent(ExpandTrigger.self, forKey: .expandTrigger) ?? d.expandTrigger
        pillWindow = try c.decodeIfPresent(PillWindow.self, forKey: .pillWindow) ?? d.pillWindow
        pillStyle = try c.decodeIfPresent(PillStyle.self, forKey: .pillStyle) ?? d.pillStyle
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? d.alertsEnabled
        alertThresholds = try c.decodeIfPresent([Int].self, forKey: .alertThresholds) ?? d.alertThresholds
        resetAlerts = try c.decodeIfPresent(Bool.self, forKey: .resetAlerts) ?? d.resetAlerts
        alertSound = try c.decodeIfPresent(Bool.self, forKey: .alertSound) ?? d.alertSound
    }

    public func providerProxy(_ p: Provider) -> ProviderProxy {
        providerProxies[p.rawValue] ?? ProviderProxy()
    }

    /// Resolves inheritance and pulls the password from the Keychain.
    public func effectiveProxy(for p: Provider) -> EffectiveProxy {
        let pp = providerProxy(p)
        let (cfg, key) = pp.useGlobal
            ? (globalProxy, ProxyCredentialKey.global)
            : (pp.config, ProxyCredentialKey.provider(p))
        let password = cfg.kind.needsServer && !cfg.username.isEmpty ? KeychainStore.password(for: key) : ""
        return EffectiveProxy(config: cfg, password: password)
    }
}

public enum SettingsStore {
    public static var fileURL: URL { Paths.appSupport.appendingPathComponent("settings.json") }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public static func save(_ settings: AppSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Finds agent homes already on this Mac.
public enum AccountDetector {
    public static func detect(existing: [Account] = [], fileManager fm: FileManager = .default) -> [Account] {
        let home = Paths.home
        var found: [Account] = []
        var seen = Set(existing.map { "\($0.provider.rawValue):\(Paths.expand($0.homePath))" })

        func add(_ provider: Provider, _ path: String) {
            let p = Paths.expand(path)
            let key = "\(provider.rawValue):\(p)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append(Account(provider: provider, homePath: Paths.abbreviate(p), label: defaultLabel(provider, p)))
        }

        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }

        let topLevel = (try? fm.contentsOfDirectory(atPath: home)) ?? []

        // Claude: ~/.claude, ~/.claude-*/~/.claude_*, children of ~/.claude_multi, $CLAUDE_CONFIG_DIR.
        var claudeDirs = topLevel
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") || ($0.hasPrefix(".claude_") && $0 != ".claude_multi") }
            .map { "\(home)/\($0)" }
        let multi = "\(home)/.claude_multi"
        if isDir(multi) {
            claudeDirs += ((try? fm.contentsOfDirectory(atPath: multi)) ?? []).sorted().map { "\(multi)/\($0)" }
        }
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { claudeDirs.append(env) }
        for d in claudeDirs where isDir(d) && looksLikeClaudeHome(d, fm: fm) { add(.claude, d) }

        // Codex: ~/.codex* containing auth.json, $CODEX_HOME.
        var codexDirs = topLevel.filter { $0.hasPrefix(".codex") }.sorted().map { "\(home)/\($0)" }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] { codexDirs.append(env) }
        for d in codexDirs where isDir(d) && fm.fileExists(atPath: d + "/auth.json") { add(.codex, d) }

        if CursorCredentials.exists(home: CursorCredentials.defaultHome) { add(.cursor, CursorCredentials.defaultHome) }
        return found
    }

    static func looksLikeClaudeHome(_ d: String, fm: FileManager) -> Bool {
        ["projects", "settings.json", ".claude.json", "history.jsonl", ".credentials.json"]
            .contains { fm.fileExists(atPath: "\(d)/\($0)") }
    }

    public static func defaultLabel(_ provider: Provider, _ path: String) -> String {
        switch provider {
        case .claude:
            if let email = ClaudeCredentials.email(home: path) { return email }
        case .codex:
            if let email = CodexCredentials.load(home: path)?.email { return email }
        case .cursor:
            if let email = CursorCredentials.value(forKey: "cursorAuth/cachedEmail", home: path) { return email }
            return "Cursor"
        }
        return (path as NSString).lastPathComponent
    }
}
