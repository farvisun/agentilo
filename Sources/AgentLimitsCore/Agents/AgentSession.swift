import Foundation

public enum AgentState: String, Codable, Sendable {
    case working
    /// Asked a question or finished and wants the next prompt, per the agent.
    case waitingInput
    /// An approval prompt is open.
    case waitingPermission
    /// Finished its turn since the user last looked.
    case done
    case idle

    public var needsAttention: Bool { self == .waitingInput || self == .waitingPermission }

    /// Sort order in the list: what needs the user first.
    var rank: Int {
        switch self {
        case .waitingPermission: 0
        case .waitingInput: 1
        case .done: 2
        case .working: 3
        case .idle: 4
        }
    }
}

/// One running agent: a herdr pane, or a hook session outside herdr.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var agent: String
    public var sessionID: String?
    public var cwd: String?
    /// The task name the agent put in its terminal title (herdr).
    public var title: String?
    public var state: AgentState
    public var tool: String?
    public var detail: String?
    public var herdr: HerdrLocation?
    public var focused = false
    public var stateSince: Date
    public var lastEventAt: Date
    /// Last time a hook (not herdr) reported on this session.
    public var lastHookAt: Date?

    public var provider: Provider? { Provider(rawValue: agent) }
    public var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? agent }
}

/// A state change worth telling the user about.
public struct AgentTransition: Equatable, Sendable {
    public var session: AgentSession
    public var from: AgentState?
    public var to: AgentState
    /// How long the session was in `from`.
    public var after: TimeInterval
}

/// Merges hook events and herdr snapshots into one list of sessions.
public struct AgentSessionStore: Equatable, Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]

    /// Sessions nothing has reported on for this long are dropped.
    static let staleAfter: TimeInterval = 30 * 60
    /// Hooks know better than herdr's screen reading for this long after they report.
    static let hookAuthority: TimeInterval = 3

    public init() {}

    /// What needs the user first, then by recency.
    public var ordered: [AgentSession] {
        sessions.values.sorted { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.stateSince > b.stateSince
        }
    }

    public var attentionCount: Int { sessions.values.filter(\.state.needsAttention).count }

    public static func key(agent: String, sessionID: String?, herdr: HerdrLocation?) -> String {
        if let pane = herdr?.pane { return "herdr:\(pane)" }
        return "\(agent):\(sessionID ?? "unknown")"
    }

    // MARK: Hooks

    @discardableResult
    public mutating func apply(_ e: AgentEvent) -> [AgentTransition] {
        let key = Self.key(agent: e.agent, sessionID: e.sessionID, herdr: e.herdr)
        if e.kind == .sessionEnd {
            sessions[key] = nil
            return []
        }
        var s = sessions[key] ?? AgentSession(
            id: key, agent: e.agent, sessionID: e.sessionID, cwd: e.cwd, state: .idle,
            herdr: e.herdr, stateSince: e.at, lastEventAt: e.at
        )
        let old = sessions[key]?.state
        s.agent = e.agent
        s.sessionID = e.sessionID ?? s.sessionID
        s.cwd = e.cwd ?? s.cwd
        s.herdr = e.herdr ?? s.herdr
        s.lastEventAt = e.at
        s.lastHookAt = e.at

        let next: AgentState
        switch e.kind {
        case .sessionStart:
            next = s.state == .working ? .working : .idle
        case .prompt:
            next = .working
            s.tool = nil
            s.detail = e.detail
        case .preTool:
            next = .working
            s.tool = e.tool
            s.detail = e.detail
        case .postTool:
            next = .working
        case .notification:
            next = Self.notificationState(e)
            s.detail = e.detail ?? s.detail
        case .permission:
            next = .waitingPermission
            s.tool = e.tool ?? s.tool
            s.detail = e.detail ?? s.detail
        case .stop:
            next = .done
            s.tool = nil
        case .sessionEnd:
            next = .idle
        }
        return set(&s, next, previous: old, at: e.at)
    }

    static func notificationState(_ e: AgentEvent) -> AgentState {
        switch e.notificationType {
        case "permission_prompt": return .waitingPermission
        case "idle_prompt", "elicitation_dialog": return .waitingInput
        default:
            let text = (e.detail ?? "").lowercased()
            return text.contains("permission") || text.contains("approve") ? .waitingPermission : .waitingInput
        }
    }

    // MARK: herdr

    /// Applies a full `herdr agent list`. herdr panes that vanished are dropped.
    @discardableResult
    public mutating func applyHerdr(_ agents: [HerdrAgent], now: Date = Date()) -> [AgentTransition] {
        var out: [AgentTransition] = []
        var seen = Set<String>()
        for a in agents {
            let key = Self.key(agent: a.agent, sessionID: a.sessionID, herdr: a.location)
            seen.insert(key)
            // A hook session that started before we knew its pane: adopt it.
            if sessions[key] == nil, let sid = a.sessionID,
               let other = sessions.first(where: { $0.value.herdr == nil && $0.value.sessionID == sid })?.key {
                var moved = sessions.removeValue(forKey: other)!
                moved.id = key
                sessions[key] = moved
            }
            var s = sessions[key] ?? AgentSession(
                id: key, agent: a.agent, sessionID: a.sessionID, cwd: a.cwd, state: .idle,
                herdr: a.location, stateSince: now, lastEventAt: now
            )
            let old = sessions[key]?.state
            s.agent = a.agent
            s.sessionID = a.sessionID ?? s.sessionID
            s.cwd = a.cwd ?? s.cwd
            s.title = a.title ?? s.title
            s.herdr = a.location
            s.focused = a.focused
            s.lastEventAt = now

            let fresh = s.lastHookAt.map { now.timeIntervalSince($0) < Self.hookAuthority } ?? false
            var next = s.state
            switch a.status {
            case .working:
                if !fresh { next = .working }
            case .blocked:
                if !s.state.needsAttention { next = .waitingPermission }
            case .idle:
                // Idle after work means the turn finished; idle at start is just idle.
                // A closed approval prompt likewise; a question stays open until the next prompt.
                if (s.state == .working || s.state == .waitingPermission) && !fresh { next = .done }
            case .unknown:
                break
            }
            if old == nil { next = a.status == .working ? .working : (a.status == .blocked ? .waitingPermission : .idle) }
            out += set(&s, next, previous: old, at: now)
        }
        for (key, s) in sessions where s.herdr != nil && !seen.contains(key) {
            // A pane can report through hooks a moment before herdr lists it.
            if let hook = s.lastHookAt, now.timeIntervalSince(hook) < 10 { continue }
            sessions[key] = nil
        }
        return out
    }

    // MARK: Housekeeping

    /// Viewing a finished session (or its pane being focused) makes it plain idle.
    public mutating func acknowledge(_ id: String, now: Date = Date()) {
        guard var s = sessions[id], s.state == .done else { return }
        s.state = .idle
        s.stateSince = now
        sessions[id] = s
    }

    public mutating func prune(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEventAt) < Self.staleAfter }
    }

    private mutating func set(_ s: inout AgentSession, _ next: AgentState, previous: AgentState?, at: Date) -> [AgentTransition] {
        let changed = previous != next
        let since = s.stateSince
        if changed { s.state = next; s.stateSince = at }
        sessions[s.id] = s
        guard changed else { return [] }
        return [AgentTransition(session: s, from: previous, to: next, after: at.timeIntervalSince(since))]
    }
}
