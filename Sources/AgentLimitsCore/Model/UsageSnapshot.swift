import Foundation

public enum WindowKind: String, Codable, Sendable {
    case session
    case weekly
    case billing
    case other
}

/// A single limit window as reported by a provider (5-hour session, weekly, billing cycle...).
public struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: WindowKind
    public var title: String
    /// 0...100 (may exceed 100 for overage).
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Total window length; needed for pace prediction.
    public var windowLength: TimeInterval?
    /// Extra text such as "$12.40 of $20.00".
    public var detail: String?

    public init(
        id: String,
        kind: WindowKind,
        title: String,
        usedPercent: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowLength = windowLength
        self.detail = detail
    }

    public func pace(now: Date = Date()) -> Pace {
        Pace.evaluate(usedPercent: usedPercent, resetsAt: resetsAt, windowLength: windowLength, now: now)
    }
}

/// Where a snapshot's numbers came from.
public enum SnapshotSource: String, Codable, Sendable {
    /// Fresh from the provider server.
    case live
    /// Last server response, kept on disk.
    case cached
    /// Read from the agent's own session logs (Codex writes exact limits there).
    case localLog
    /// Last server response advanced by tokens logged since (Claude).
    case estimated
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public var windows: [UsageWindow]
    public var plan: String?
    public var email: String?
    public var fetchedAt: Date
    public var source: SnapshotSource

    public init(
        windows: [UsageWindow],
        plan: String? = nil,
        email: String? = nil,
        fetchedAt: Date = Date(),
        source: SnapshotSource = .live
    ) {
        self.windows = windows
        self.plan = plan
        self.email = email
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Windows whose reset time has passed start over at 0% in their next period.
    /// Weekly windows repeat on a fixed schedule; a session window's next end is unknown.
    public func rolledOver(now: Date = Date()) -> UsageSnapshot {
        var copy = self
        copy.windows = windows.map { w in
            guard let reset = w.resetsAt, reset <= now else { return w }
            var n = w
            n.usedPercent = 0
            // A new session window only starts with the next request, so its end is unknown.
            if let length = w.windowLength, length > 0, w.kind != .session {
                let periods = (now.timeIntervalSince(reset) / length).rounded(.down) + 1
                n.resetsAt = reset.addingTimeInterval(periods * length)
            } else {
                n.resetsAt = nil
            }
            return n
        }
        return copy
    }

    /// The window shown in the pill: the session window, else the first one.
    public var primary: UsageWindow? {
        windows.first(where: { $0.kind == .session }) ?? windows.first
    }

    /// The window closest to trouble: worst pace first, then highest usage.
    public func mostCritical(now: Date = Date()) -> UsageWindow? {
        windows.max { a, b in
            let pa = a.pace(now: now).severity, pb = b.pace(now: now).severity
            if pa != pb { return pa < pb }
            return a.usedPercent < b.usedPercent
        }
    }
}

public enum Formatters {
    public static func compactTokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// "7:24 PM" today, "Thu 7:24 PM" within a week, otherwise "Oct 30".
    public static func resetTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return f.string(from: date)
    }

    /// "2h 14m", "3d 4h", "12m".
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3_600, m = (s % 3_600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
