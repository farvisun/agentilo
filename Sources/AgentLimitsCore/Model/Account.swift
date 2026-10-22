import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    /// Host the provider's usage endpoint lives on; used by the proxy connection test.
    public var probeURL: URL {
        switch self {
        case .claude: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        case .codex: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        case .cursor: URL(string: "https://cursor.com/api/usage-summary")!
        }
    }
}

/// One signed-in agent home. Each home is its own account with its own limits,
/// and its logs feed the local token statistics.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    /// Agent home directory (`~/.claude`, `~/.codex_work`, Cursor's globalStorage dir, ...).
    public var homePath: String
    public var label: String
    public var enabled: Bool
    /// Query the provider server for limits. When off, the home only feeds token stats.
    public var trackLimits: Bool

    public init(
        id: UUID = UUID(),
        provider: Provider,
        homePath: String,
        label: String,
        enabled: Bool = true,
        trackLimits: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.homePath = homePath
        self.label = label
        self.enabled = enabled
        self.trackLimits = trackLimits
    }

    public var homeURL: URL { URL(fileURLWithPath: Paths.expand(homePath)) }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    /// Expands `~` and strips any trailing slash so the path matches what agents hash.
    public static func expand(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Replaces the home prefix with `~` for display.
    public static func abbreviate(_ path: String) -> String {
        (Paths.expand(path) as NSString).abbreviatingWithTildeInPath
    }

    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AgentLimits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
