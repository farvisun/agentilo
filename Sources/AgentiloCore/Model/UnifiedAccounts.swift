import Foundation

/// Several accounts of one provider shown as one: each limit once, with the share used across
/// the accounts that have it. Alerts, the pill and account suggestions stay per account.
public enum UnifiedAccounts {
    /// Providers whose accounts can be shown as one (same limits on every account).
    public static let providers: [Provider] = [.claude, .codex]
    /// Resets this close together count as one schedule, so the pace still means something.
    static let resetSpread: TimeInterval = 1_800

    /// Merges the accounts' snapshots. A limit is the average of its accounts (each capped at
    /// 100%), so it reads 100% only when every account is used up. Its reset is the soonest one.
    public static func merge(_ snaps: [UsageSnapshot], now: Date = Date()) -> UsageSnapshot? {
        guard let first = snaps.first else { return nil }
        var order: [String] = []
        var byId: [String: [UsageWindow]] = [:]
        for s in snaps {
            for w in s.windows {
                if byId[w.id] == nil { order.append(w.id) }
                byId[w.id, default: []].append(w)
            }
        }
        let windows = order.compactMap { id -> UsageWindow? in
            guard let ws = byId[id], var w = ws.first else { return nil }
            if ws.count == 1 { return w }
            if w.kind == .balance {
                w.detail = ws.compactMap(\.detail).joined(separator: " + ")
                return w
            }
            w.usedPercent = ws.map { min($0.usedPercent, 100) }.reduce(0, +) / Double(ws.count)
            let resets = ws.compactMap(\.resetsAt).filter { $0 > now }
            w.resetsAt = resets.min()
            if let lo = resets.min(), let hi = resets.max(), hi.timeIntervalSince(lo) > resetSpread {
                // Different schedules: an average has no single pace.
                w.windowLength = nil
            }
            w.detail = nil
            return w
        }
        let plans = Set(snaps.compactMap(\.plan))
        let grants = snaps.compactMap(\.resetGrants)
        let worst: SnapshotSource = snaps.map(\.source).first { $0 != .live } ?? .live
        return UsageSnapshot(
            windows: windows,
            plan: plans.count > 1 ? "Multiple" : plans.first,
            email: nil,
            fetchedAt: snaps.map(\.fetchedAt).min() ?? first.fetchedAt,
            source: worst,
            resetGrants: grants.isEmpty ? nil : ResetGrants(
                available: grants.map(\.available).reduce(0, +),
                nextExpiry: grants.compactMap(\.nextExpiry).min()
            )
        )
    }

    /// One line per account for a merged limit: "me@work 40%".
    public static func breakdown(_ windowId: String, _ items: [(label: String, snapshot: UsageSnapshot)]) -> String {
        items.compactMap { item -> String? in
            guard let w = item.snapshot.windows.first(where: { $0.id == windowId }) else { return nil }
            let value = w.kind == .balance ? (w.detail ?? "") : "\(Int(w.usedPercent.rounded()))%"
            return "\(item.label)  \(value)"
        }.joined(separator: "\n")
    }
}
