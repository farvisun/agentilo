import Foundation

/// A Claude Code permission prompt, sent by the `PermissionRequest` hook bridge to `/v1/permission`.
public struct ApprovalRequest: Codable, Equatable, Sendable, Identifiable {
    /// Nonce chosen by the bridge; the answer goes back on the same connection.
    public var id: String
    public var event: AgentEvent
    /// What the tool is about to do, in full (whole command, file path, ...).
    public var input: String?
    /// Claude Code's `permission_suggestions` as JSON, echoed back for "always allow".
    public var suggestions: String?

    public init(id: String = UUID().uuidString, event: AgentEvent, input: String?, suggestions: String?) {
        self.id = id
        self.event = event
        self.input = input
        self.suggestions = suggestions
    }

    public var canAlwaysAllow: Bool { (suggestions.flatMap { $0.isEmpty ? nil : $0 } ?? "[]") != "[]" }

    public static func from(hookInput json: [String: Any], agent: String, environment env: [String: String]) -> ApprovalRequest {
        let toolInput = json["tool_input"] as? [String: Any]
        var input: String?
        if let cmd = toolInput?["command"] as? String {
            input = cmd.prefixed(800)
        } else if let path = (toolInput?["file_path"] as? String) ?? (toolInput?["notebook_path"] as? String) {
            input = path
        } else if let toolInput, let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys, .withoutEscapingSlashes]) {
            input = String(decoding: data, as: UTF8.self).prefixed(400)
        }
        var suggestions: String?
        if let s = json["permission_suggestions"], let data = try? JSONSerialization.data(withJSONObject: s) {
            suggestions = String(decoding: data, as: UTF8.self)
        }
        return ApprovalRequest(
            event: AgentEvent.from(hookInput: json, agent: agent, kind: .permission, environment: env),
            input: input, suggestions: suggestions
        )
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allow
    /// Allow, and apply Claude Code's own suggestion (an allow rule, ...) so it stops asking.
    case allowAlways
    case deny
    /// No answer: Claude Code shows its usual prompt in the terminal.
    case none
}

public struct ApprovalResponse: Codable, Equatable, Sendable {
    public var decision: ApprovalDecision

    public init(decision: ApprovalDecision) { self.decision = decision }

    /// What the hook prints on stdout, or nil to leave the decision to the terminal prompt.
    public func hookOutput(for request: ApprovalRequest) -> Data? {
        var decision: [String: Any]
        switch self.decision {
        case .none:
            return nil
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow"]
            if let s = request.suggestions, let data = s.data(using: .utf8),
               let updates = try? JSONSerialization.jsonObject(with: data) as? [Any], !updates.isEmpty {
                decision["updatedPermissions"] = updates
            }
        case .deny:
            decision = ["behavior": "deny", "message": "Denied from the Agentilo notch."]
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }
}
