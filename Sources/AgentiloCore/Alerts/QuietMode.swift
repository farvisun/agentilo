import Foundation

/// Hours when alerts stay silent, e.g. 22:00–08:00 on weekdays.
public struct QuietSchedule: Codable, Equatable, Sendable {
    public var enabled = false
    /// Minutes after midnight. `start > end` wraps past midnight; `start == end` is all day.
    public var start = 22 * 60
    public var end = 8 * 60
    /// `Calendar` weekdays (1 = Sunday … 7 = Saturday) on which quiet hours *begin*.
    public var days: Set<Int> = Set(1...7)

    public init(enabled: Bool = false, start: Int = 22 * 60, end: Int = 8 * 60, days: Set<Int> = Set(1...7)) {
        self.enabled = enabled
        self.start = start
        self.end = end
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietSchedule()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? d.start
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? d.end
        days = try c.decodeIfPresent(Set<Int>.self, forKey: .days) ?? d.days
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start == end { return days.contains(weekday) }
        if start < end { return days.contains(weekday) && minute >= start && minute < end }
        // Overnight: the evening part belongs to today, the early morning to yesterday.
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (days.contains(weekday) && minute >= start) || (days.contains(yesterday) && minute < end)
    }
}

/// Why alerts are silent right now, if they are.
public enum QuietReason: Equatable, Sendable {
    /// Turned on by hand (`agentilo quiet on`, or "until I turn it back on").
    case manual
    case snoozed(until: Date)
    case schedule
}

public enum QuietMode {
    public static func reason(
        now: Date, schedule: QuietSchedule, snoozeUntil: Date?, manual: Bool, calendar: Calendar = .current
    ) -> QuietReason? {
        if manual { return .manual }
        if let snoozeUntil, snoozeUntil > now { return .snoozed(until: snoozeUntil) }
        return schedule.contains(now, calendar: calendar) ? .schedule : nil
    }
}

/// Body of `POST /v1/quiet`, sent by `agentilo quiet`.
public struct QuietRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case on, off, snooze, status }
    public var action: Action
    /// For `.snooze`.
    public var minutes: Int?

    public init(action: Action, minutes: Int? = nil) {
        self.action = action
        self.minutes = minutes
    }

    /// `on`, `off`, `status`, `45m`, `2h`, or a bare number of minutes.
    public init?(argument: String) {
        let a = argument.lowercased()
        switch a {
        case "on": self.init(action: .on)
        case "off", "resume": self.init(action: .off)
        case "status", "": self.init(action: .status)
        default:
            let unit = a.last
            let digits = unit == "m" || unit == "h" ? String(a.dropLast()) : a
            guard let n = Int(digits), n > 0 else { return nil }
            self.init(action: .snooze, minutes: unit == "h" ? n * 60 : n)
        }
    }

    public func apply(to s: inout AppSettings, now: Date = Date()) {
        switch action {
        case .on:
            s.quietManual = true
        case .off:
            s.quietManual = false
            s.snoozeUntil = nil
        case .snooze:
            s.quietManual = false
            s.snoozeUntil = now.addingTimeInterval(TimeInterval((minutes ?? 60) * 60))
        case .status:
            break
        }
    }
}

/// Reply to `POST /v1/quiet`, and what `agentilo quiet status` prints.
public struct QuietStatus: Codable, Equatable, Sendable {
    public var quiet: Bool
    /// manual, snoozed or schedule.
    public var reason: String?
    public var until: Date?

    public init(_ reason: QuietReason?) {
        quiet = reason != nil
        switch reason {
        case .manual: self.reason = "manual"
        case .snoozed(let date): self.reason = "snoozed"; until = date
        case .schedule: self.reason = "schedule"
        case nil: break
        }
    }

    public var line: String {
        switch reason {
        case "manual": "Quiet until turned off"
        case "snoozed": "Snoozed until \(until.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "later")"
        case "schedule": "Quiet hours"
        default: "Alerts on"
        }
    }
}
