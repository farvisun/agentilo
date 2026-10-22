import Foundation

/// The stable, versioned limits document served at `/v1/limits` and printed by `agentlimits limits`.
/// Never carries credentials; account labels (often emails) only when allowed.
public struct LimitsPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var generatedAt: Date
    /// "app" when served by the running app, "cache" when read from disk without it.
    public var origin: String
    public var accounts: [AccountLimits]

    public struct AccountLimits: Codable, Equatable, Sendable {
        public var id: UUID
        public var provider: Provider
        public var label: String
        public var plan: String?
        public var source: SnapshotSource?
        public var fetchedAt: Date?
        public var error: String?
        public var windows: [WindowLimits]
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
        now: Date = Date()
    ) -> LimitsPayload {
        var counters: [Provider: Int] = [:]
        let items = accounts.map { acct -> AccountLimits in
            counters[acct.provider, default: 0] += 1
            let snap = snapshots[acct.id]
            return AccountLimits(
                id: acct.id,
                provider: acct.provider,
                label: includeLabels ? acct.label : "\(acct.provider.displayName) \(counters[acct.provider]!)",
                plan: snap?.plan,
                source: snap?.source,
                fetchedAt: snap?.fetchedAt,
                error: errors[acct.id],
                windows: (snap?.windows ?? []).map { window($0, now: now) }
            )
        }
        return LimitsPayload(version: currentVersion, generatedAt: now, origin: origin, accounts: items)
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

    /// One line for a status bar: "Claude S 16% W 7% · Codex S 12% W 61%".
    /// Accounts of one provider are told apart only when there are several.
    public func shortLine() -> String {
        let perProvider = Dictionary(grouping: accounts, by: \.provider).mapValues(\.count)
        return accounts.filter { !$0.windows.isEmpty }.map { a in
            let name = (perProvider[a.provider] ?? 0) > 1 ? a.label : a.provider.displayName
            let parts = a.windows.prefix(2).map { w -> String in
                let letter = switch w.kind {
                case .session: "S"
                case .weekly: "W"
                case .billing: "M"
                case .other: String(w.title.prefix(1))
                }
                return "\(letter) \(Int(w.usedPercent.rounded()))%\(w.pace == "limitReached" || w.pace == "runsOut" ? "!" : "")"
            }
            return ([name] + parts).joined(separator: " ")
        }.joined(separator: " · ")
    }
}
