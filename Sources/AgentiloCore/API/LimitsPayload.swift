import Foundation

/// The stable, versioned limits document served at `/v1/limits` and printed by `agentilo limits`.
/// Never carries credentials; account labels (often emails) only when allowed.
public struct LimitsPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    /// "app" when served by the running app, "cache" when read from disk without it.
    public var origin: String
    public var accounts: [AccountLimits]
    /// While Keep awake holds sleep off: "idle" or "lidClosed". Absent otherwise.
    public var keepAwake: KeepAwakeLevel?

    public struct AccountLimits: Codable, Equatable, Sendable {
        public var id: UUID
        public var provider: Provider
        public var label: String
        public var plan: String?
        public var source: SnapshotSource?
        public var fetchedAt: Date?
        /// Two refresh intervals after `fetchedAt`. Past it the numbers are `stale`: the app is not
        /// running, or its fetches for this account keep failing.
        public var expiresAt: Date?
        public var stale: Bool?
        public var error: String?
        public var windows: [WindowLimits]
        /// One-off limit resets available to the account. Absent when there are none.
        public var resetGrants: ResetGrants?
    }

    public struct WindowLimits: Codable, Equatable, Sendable {
        public var id: String
        public var kind: WindowKind
        public var title: String
        public var usedPercent: Double
        public var remainingPercent: Double
        public var resetsAt: Date?
        /// unknown, onTrack, ahead, runsOut, limitReached.
        public var pace: String
        public var runsOutAt: Date?
        public var detail: String?
    }

    public static func build(
        accounts: [Account],
        snapshots: [UUID: UsageSnapshot],
        errors: [UUID: String] = [:],
        includeLabels: Bool,
        origin: String,
        keepAwake: KeepAwakeLevel? = nil,
        refreshInterval: TimeInterval = 120,
        now: Date = Date()
    ) -> LimitsPayload {
        var counters: [Provider: Int] = [:]
        let items = accounts.map { acct -> AccountLimits in
            counters[acct.provider, default: 0] += 1
            let snap = snapshots[acct.id]
            let expires = snap.map { $0.fetchedAt.addingTimeInterval(2 * max(30, refreshInterval)) }
            return AccountLimits(
                id: acct.id,
                provider: acct.provider,
                label: includeLabels ? acct.label : "\(acct.provider.displayName) \(counters[acct.provider]!)",
                plan: snap?.plan,
                source: snap?.source,
                fetchedAt: snap?.fetchedAt,
                expiresAt: expires,
                stale: snap == nil ? nil : expires.map { now > $0 },
                error: errors[acct.id],
                windows: (snap?.windows ?? []).map { window($0, now: now) },
                resetGrants: snap?.resetGrants
            )
        }
        return LimitsPayload(
            version: currentVersion, generatedAt: now, origin: origin, accounts: items,
            keepAwake: keepAwake == .off ? nil : keepAwake
        )
    }

    static func window(_ w: UsageWindow, now: Date) -> WindowLimits {
        let pace = w.pace(now: now)
        let (name, runsOut): (String, Date?) = switch pace {
        case .unknown: ("unknown", nil)
        case .onTrack: ("onTrack", nil)
        case .ahead: ("ahead", nil)
        case .runsOut(let d): ("runsOut", d)
        case .limitReached: ("limitReached", nil)
        }
        return WindowLimits(
            id: w.id, kind: w.kind, title: w.title,
            usedPercent: (w.usedPercent * 10).rounded() / 10,
            remainingPercent: (max(0, 100 - w.usedPercent) * 10).rounded() / 10,
            resetsAt: w.resetsAt, pace: name, runsOutAt: runsOut, detail: w.detail
        )
    }

    /// Only the accounts a CLI argument names: a provider ("claude", "codex", "OpenCode Go"),
    /// an account label, or the start of an account id. Nil when nothing matches.
    public func filtered(_ query: String) -> LimitsPayload? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return self }
        let matches = accounts.filter { a in
            a.provider.rawValue.lowercased() == q || a.provider.displayName.lowercased() == q
                || a.label.lowercased() == q || (q.count >= 4 && a.id.uuidString.lowercased().hasPrefix(q))
        }
        guard !matches.isEmpty else { return nil }
        var copy = self
        copy.accounts = matches
        return copy
    }

    /// One line for a status bar: "Claude S 16% W 7% · Codex S 12% W 61%", plus "awake" or
    /// "awake (lid)" while Keep awake holds sleep off.
    /// Accounts of one provider are told apart only when there are several.
    public func shortLine() -> String {
        let perProvider = Dictionary(grouping: accounts, by: \.provider).mapValues(\.count)
        let awake: [String] = switch keepAwake {
        case .idle?: ["awake"]
        case .lidClosed?: ["awake (lid)"]
        case .off?, nil: []
        }
        return (accounts.filter { !$0.windows.isEmpty }.map { a in
            let name = (perProvider[a.provider] ?? 0) > 1 ? a.label : a.provider.displayName
            let parts = a.windows.filter { $0.kind != .balance }.prefix(2).map { w -> String in
                let letter = switch w.kind {
                case .session: "S"
                case .weekly: "W"
                case .billing: "M"
                case .other: String(w.title.prefix(1))
                case .balance: "$"
                }
                return "\(letter) \(Int(w.usedPercent.rounded()))%\(w.pace == "limitReached" || w.pace == "runsOut" ? "!" : "")"
            }
            return ([name] + parts).joined(separator: " ")
        } + awake).joined(separator: " · ")
    }
}
