import Foundation
import Security

/// What an agent hook reports, normalized across Claude Code and Codex.
public enum AgentEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case prompt
    case preTool
    case postTool
    case notification
    case permission
    case stop
    case sessionEnd

    /// Hook event names, shared by Claude Code `settings.json` and Codex `hooks.json`.
    public var hookName: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .prompt: "UserPromptSubmit"
        case .preTool: "PreToolUse"
        case .postTool: "PostToolUse"
        case .notification: "Notification"
        case .permission: "PermissionRequest"
        case .stop: "Stop"
        case .sessionEnd: "SessionEnd"
        }
    }
}

/// One hook call, as posted by `agentlimits hook <agent> <event>` to `/v1/events`.
public struct AgentEvent: Codable, Equatable, Sendable {
    public var agent: String
    public var kind: AgentEventKind
    public var sessionID: String?
    public var cwd: String?
    public var tool: String?
    /// Notification text, or a short summary of the tool call.
    public var detail: String?
    /// Claude's notification type: permission_prompt, idle_prompt, ...
    public var notificationType: String?
    public var herdr: HerdrLocation?
    public var at: Date

    public init(
        agent: String, kind: AgentEventKind, sessionID: String? = nil, cwd: String? = nil, tool: String? = nil,
        detail: String? = nil, notificationType: String? = nil, herdr: HerdrLocation? = nil, at: Date = Date()
    ) {
        self.agent = agent
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.tool = tool
        self.detail = detail
        self.notificationType = notificationType
        self.herdr = herdr
        self.at = at
    }

    /// Builds the event from a hook's stdin JSON and the hook process environment.
    public static func from(
        hookInput json: [String: Any], agent: String, kind: AgentEventKind,
        environment env: [String: String], at: Date = Date()
    ) -> AgentEvent {
        let tool = json["tool_name"] as? String
        let detail = (json["message"] as? String)
            ?? toolSummary(tool: tool, input: json["tool_input"] as? [String: Any])
            ?? (json["prompt"] as? String).map { String($0.prefix(120)) }
        return AgentEvent(
            agent: agent,
            kind: kind,
            sessionID: (json["session_id"] as? String) ?? (json["sessionId"] as? String),
            cwd: (json["cwd"] as? String) ?? env["PWD"],
            tool: tool,
            detail: detail,
            notificationType: json["notification_type"] as? String,
            herdr: HerdrLocation(environment: env)
        )
    }

    /// "npm test", "AppState.swift", or nil: one line that says what the tool is about to touch.
    public static func toolSummary(tool: String?, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let cmd = input["command"] as? String {
            return String(cmd.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces).prefixed(160)
        }
        if let cmd = input["command"] as? [String] { return cmd.joined(separator: " ").prefixed(160) }
        for key in ["file_path", "notebook_path", "path"] {
            if let p = input[key] as? String { return (p as NSString).lastPathComponent }
        }
        for key in ["url", "pattern", "query", "description"] {
            if let v = input[key] as? String { return v.prefixed(160) }
        }
        return nil
    }
}

/// Where an agent runs inside herdr, from the pane's `HERDR_*` environment.
public struct HerdrLocation: Codable, Equatable, Sendable {
    public var pane: String
    public var tab: String?
    public var workspace: String?

    public init(pane: String, tab: String? = nil, workspace: String? = nil) {
        self.pane = pane
        self.tab = tab
        self.workspace = workspace
    }

    public init?(environment env: [String: String]) {
        guard let pane = env["HERDR_PANE_ID"], !pane.isEmpty else { return nil }
        self.init(pane: pane, tab: env["HERDR_TAB_ID"], workspace: env["HERDR_WORKSPACE_ID"])
    }
}

extension String {
    func prefixed(_ n: Int) -> String { count > n ? String(prefix(n - 1)) + "…" : self }
}

/// Shared secret between the app and its hook bridge, so other local processes
/// cannot post fake agent events (or, later, answer approvals).
public enum HookToken {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("hook-token") }
    public static let header = "x-agentlimits-token"

    public static func load() -> String? {
        (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The token, created on first use with owner-only permissions.
    public static func ensure() -> String {
        if let t = load(), !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}
