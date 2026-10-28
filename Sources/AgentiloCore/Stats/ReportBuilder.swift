import Foundation

public enum ReportGroup: String, CaseIterable, Sendable, Identifiable {
    case project
    case model
    case provider

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .project: "Project"
        case .model: "Model"
        case .provider: "Agent"
        }
    }
}

public struct ReportRow: Hashable, Sendable, Identifiable {
    public var name: String
    public var usage: DayUsage
    public var previous: DayUsage
    /// Of the period's tokens, 0...1.
    public var share: Double
    public var id: String { name }

    public var tokens: Int { usage.tokens }
    public var cost: Double { usage.cost }
    public var prompts: Int { usage.prompts }
}

/// One stacked bar segment: a group's tokens and cost on one day.
public struct ReportPoint: Hashable, Sendable, Identifiable {
    public var day: Date
    public var group: String
    public var usage: DayUsage
    public var id: String { "\(DayKey.int(day))|\(group)" }
}

public struct Report: Sendable, Equatable {
    /// First and last day of the period (start of day).
    public var start: Date
    public var end: Date
    public var days: Int
    public var total: DayUsage
    /// The same number of days just before `start`.
    public var previous: DayUsage
    public var activeDays: Int
    /// False when part of the previous period predates breakdowns, so per-row changes are unknown.
    public var previousBrokenDown: Bool
    /// Largest first by tokens.
    public var rows: [ReportRow]
    /// Per day and group, oldest first; groups beyond the top few are summed into "Other".
    public var series: [ReportPoint]

    /// Change against the previous period, e.g. 0.25 for +25%; nil when there was nothing before.
    public static func change(_ now: Double, _ before: Double) -> Double? {
        before > 0 ? now / before - 1 : nil
    }
}

public enum ReportBuilder {
    /// Days without a breakdown (recorded before 0.4) count here.
    public static let unattributed = "Earlier, not broken down"
    public static let other = "Other"

    /// The `days` days ending with `end`'s day. Rows (and the chart's top groups) are largest first
    /// by tokens, or by cost with `rankByCost`.
    public static func report(
        history: [DayRecord], days: Int, end: Date = Date(), groupBy: ReportGroup,
        rankByCost: Bool = false, seriesGroups: Int = 5, calendar: Calendar = .current
    ) -> Report {
        let endDay = calendar.startOfDay(for: end)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: endDay)!
        let prevStart = calendar.date(byAdding: .day, value: -days, to: start)!
        let byDay = Dictionary(history.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })

        func dates(from: Date, count: Int) -> [Date] {
            (0..<count).map { calendar.date(byAdding: .day, value: $0, to: from)! }
        }
        func groups(_ r: DayRecord) -> [String: DayUsage] {
            let split: [String: DayUsage]? = switch groupBy {
            case .project: r.projects
            case .model: r.models
            case .provider: r.providers
            }
            if let split {
                // Tokens and cost the split does not cover (none today) stay visible.
                var out = split
                let covered = split.values.reduce(DayUsage(), +)
                let rest = DayUsage(tokens: r.tokens - covered.tokens, cost: max(0, r.cost - covered.cost))
                if rest.tokens > 0 { out[unattributed, default: DayUsage()] = out[unattributed, default: DayUsage()] + rest }
                return out
            }
            return r.active ? [unattributed: DayUsage(tokens: r.tokens, cost: r.cost, prompts: r.prompts)] : [:]
        }
        func total(_ r: DayRecord?) -> DayUsage {
            r.map { DayUsage(tokens: $0.tokens, cost: $0.cost, prompts: $0.prompts) } ?? DayUsage()
        }

        let period = dates(from: start, count: days).map { ($0, byDay[DayKey.int($0, calendar: calendar)]) }
        let before = dates(from: prevStart, count: days).map { byDay[DayKey.int($0, calendar: calendar)] }

        var now: [String: DayUsage] = [:], prev: [String: DayUsage] = [:]
        for (_, r) in period { if let r { for (k, v) in groups(r) { now[k] = (now[k] ?? DayUsage()) + v } } }
        for r in before { if let r { for (k, v) in groups(r) { prev[k] = (prev[k] ?? DayUsage()) + v } } }

        let sum = period.map { total($0.1) }.reduce(DayUsage(), +)
        let rows = now.map { name, u in
            ReportRow(name: name, usage: u, previous: prev[name] ?? DayUsage(),
                      share: sum.tokens > 0 ? Double(u.tokens) / Double(sum.tokens) : 0)
        }
        .sorted {
            rankByCost && $0.cost != $1.cost ? $0.cost > $1.cost : ($0.tokens, $1.name) > ($1.tokens, $0.name)
        }

        let top = Set(rows.prefix(seriesGroups).map(\.name))
        var series: [ReportPoint] = []
        for (day, r) in period {
            guard let r else { continue }
            var merged: [String: DayUsage] = [:]
            for (k, v) in groups(r) where v.tokens > 0 || v.cost > 0 {
                let key = top.contains(k) ? k : other
                merged[key] = (merged[key] ?? DayUsage()) + v
            }
            series += merged.sorted { $0.key < $1.key }.map { ReportPoint(day: day, group: $0.key, usage: $0.value) }
        }

        return Report(
            start: start, end: endDay, days: days, total: sum,
            previous: before.map(total).reduce(DayUsage(), +),
            activeDays: period.filter { $0.1?.active == true }.count,
            previousBrokenDown: prev[unattributed] == nil,
            rows: rows, series: series
        )
    }

    /// The Monday 00:00 of the week before `now`'s week, when the weekly summary covers it.
    public static func lastWeekStart(now: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!.start
        return cal.date(byAdding: .day, value: -7, to: thisWeek)!
    }
}
