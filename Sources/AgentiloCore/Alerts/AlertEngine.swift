import Foundation

/// A limit event worth interrupting for: a usage threshold crossed, a window reset, a pace
/// that runs a window out before its reset, or a long window about to reset mostly unused.
public struct LimitAlert: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case threshold(Int)
        case limitReached
        case reset
        case burningFast
        case useItOrLoseIt
    }

    /// Also the de-duplication key.
    public var id: String
    public var kind: Kind
    public var provider: Provider
    public var accountLabel: String
    public var windowTitle: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var pace: Pace

    public var title: String {
        switch kind {
        case .threshold(let t): "\(provider.displayName) \(windowTitle.lowercased()) at \(t)%"
        case .limitReached: "\(provider.displayName) \(windowTitle.lowercased()) limit reached"
        case .reset: "\(provider.displayName) \(windowTitle.lowercased()) reset"
        case .burningFast: "\(provider.displayName) \(windowTitle.lowercased()) burning fast"
        case .useItOrLoseIt:
            "\(provider.displayName) \(windowTitle.lowercased()) has \(Int((100 - usedPercent).rounded()))% left"
        }
    }

    public func message(now: Date = Date()) -> String {
        switch kind {
        case .threshold:
            if case .runsOut = pace { return pace.label(now: now) }
            return resetsAt.map { "Resets \(Formatters.resetTime($0, now: now))" } ?? pace.label(now: now)
        case .limitReached:
            return resetsAt.map { "Back \(Formatters.resetTime($0, now: now)) · in \(Formatters.countdown(to: $0, now: now))" } ?? "Wait for the reset"
        case .reset:
            return "Full allowance again"
        case .burningFast:
            let reset = resetsAt.map { " · resets \(Formatters.resetTime($0, now: now))" } ?? ""
            return pace.label(now: now) + reset
        case .useItOrLoseIt:
            return resetsAt.map { "Resets \(Formatters.resetTime($0, now: now)) · in \(Formatters.countdown(to: $0, now: now))" } ?? ""
        }
    }
}

public enum AlertEngine {
    /// A drop from at least this much usage to under `resetCeiling` counts as a reset.
    static let resetFloor: Double = 50
    static let resetCeiling: Double = 5
    /// Fired keys older than this are forgotten; longer than any window.
    static let memory: TimeInterval = 35 * 86_400
    /// "Use it or lose it": windows longer than a day that reset within this time with more than
    /// `unusedShare` percent left.
    static let unusedLead: TimeInterval = 86_400
    static let unusedShare: Double = 50

    /// Alerts for the change from `previous` to `current`. `fired` remembers what was already
    /// shown, so each threshold fires once per window period, even across relaunches.
    public static func evaluate(
        previous: UsageSnapshot?,
        current: UsageSnapshot,
        account: Account,
        thresholds: [Int],
        resetAlerts: Bool,
        burningFast: Bool = false,
        useItOrLoseIt: Bool = false,
        fired: inout [String: Date],
        now: Date = Date()
    ) -> [LimitAlert] {
        var out: [LimitAlert] = []
        for w in current.windows {
            let base = "\(account.id.uuidString)|\(w.id)"
            func alert(_ kind: LimitAlert.Kind, _ key: String) -> LimitAlert {
                LimitAlert(
                    id: key, kind: kind, provider: account.provider, accountLabel: account.label,
                    windowTitle: w.title, usedPercent: w.usedPercent, resetsAt: w.resetsAt, pace: w.pace(now: now)
                )
            }

            if resetAlerts, let old = previous?.windows.first(where: { $0.id == w.id }),
               old.usedPercent >= resetFloor, w.usedPercent < resetCeiling {
                // A new period: forget what fired in the old one.
                fired = fired.filter { !$0.key.hasPrefix(base + "|") }
                let key = "\(base)|reset|\(period(old.resetsAt))"
                if fired[key] == nil {
                    fired[key] = now
                    out.append(alert(.reset, key))
                }
                continue
            }

            if useItOrLoseIt, let a = unused(w, base: base, fired: &fired, now: now, alert: alert) {
                out.append(a)
            }

            // Only the highest crossed threshold fires; the lower ones are marked as done.
            let crossed = thresholds.sorted().filter { w.usedPercent >= Double($0) }
            guard let top = crossed.last else {
                // Below every threshold: the pace may still run the window out before it resets.
                if burningFast, let a = burning(w, base: base, fired: &fired, now: now, alert: alert) {
                    out.append(a)
                }
                continue
            }
            let keys = crossed.map { "\(base)|\($0)|\(period(w.resetsAt))" }
            guard fired[keys.last!] == nil else { continue }
            for k in keys { fired[k] = now }
            out.append(alert(top >= 100 ? .limitReached : .threshold(top), keys.last!))
        }
        fired = fired.filter { now.timeIntervalSince($0.value) < memory }
        return out
    }

    /// Fires once when the pace says the window runs out before its reset. Re-arms when the pace
    /// is back on track, so a second burst in the same window warns again.
    private static func burning(
        _ w: UsageWindow, base: String, fired: inout [String: Date], now: Date,
        alert: (LimitAlert.Kind, String) -> LimitAlert
    ) -> LimitAlert? {
        let key = "\(base)|burn|\(period(w.resetsAt))"
        switch w.pace(now: now) {
        case .runsOut:
            guard fired[key] == nil else { return nil }
            fired[key] = now
            return alert(.burningFast, key)
        case .onTrack:
            fired[key] = nil
            return nil
        default:
            return nil
        }
    }

    /// Fires once per period when a window longer than a day resets within 24 hours with more
    /// than half left. Never for billing caps or session windows.
    private static func unused(
        _ w: UsageWindow, base: String, fired: inout [String: Date], now: Date,
        alert: (LimitAlert.Kind, String) -> LimitAlert
    ) -> LimitAlert? {
        guard w.kind != .billing, let length = w.windowLength, length > 86_400,
              let reset = w.resetsAt else { return nil }
        let left = reset.timeIntervalSince(now)
        guard left > 0, left <= unusedLead, 100 - w.usedPercent > unusedShare else { return nil }
        let key = "\(base)|unused|\(period(reset))"
        guard fired[key] == nil else { return nil }
        fired[key] = now
        return alert(.useItOrLoseIt, key)
    }

    /// Reset times drift by seconds between responses; bucket them so one period keeps one key.
    static func period(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "open" }
        return String(Int((resetsAt.timeIntervalSince1970 / 1_800).rounded()))
    }
}

/// Keys of alerts already shown, so a relaunch does not repeat them.
public enum AlertStore {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("alerts.json") }

    public static func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return s
    }

    public static func save(_ fired: [String: Date]) {
        guard let data = try? JSONEncoder().encode(fired) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
