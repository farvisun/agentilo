import AgentiloCore
import SwiftUI

/// Streak, a 26-week heatmap, and today's prompts, tool calls, sessions, cost and projects.
struct ActivityPage: View {
    var stats: TokenStats

    var body: some View {
        // Fixed columns must fit the ~524pt content width: 96 + 16 + 262 + 16 + 128.
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Streak").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(stats.currentStreak)")
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    Text(stats.currentStreak == 1 ? "day" : "days").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
                Text("longest \(stats.longestStreak)").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                    .padding(.bottom, 6)
                stat("Prompts", "\(stats.todayPrompts)")
                stat("Tool calls", "\(stats.todayToolCalls)")
                stat("Sessions", "\(stats.todaySessions)")
            }
            .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Last 26 weeks").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("7 days ≈ \(money(stats.days.reduce(0) { $0 + $1.cost }))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Palette.tertiary)
                }
                Heatmap(days: stats.history)
                HStack(spacing: 3) {
                    Text("Less").font(.system(size: 8)).foregroundStyle(Palette.tertiary)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2).fill(Heatmap.color(level)).frame(width: 8, height: 8)
                    }
                    Text("More").font(.system(size: 8)).foregroundStyle(Palette.tertiary)
                }
            }
            .frame(width: Heatmap.width, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text("Today").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Text("≈ \(money(stats.todayCost))")
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                Text(stats.todayUnpriced > 0
                     ? "API prices · +\(Formatters.compactTokens(stats.todayUnpriced)) unpriced"
                     : "at API list prices")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .help("Plans are not billed per token; this is what the same usage would cost on the API.")
                    .padding(.bottom, 2)
                ForEach(stats.todayProjects.prefix(4)) { p in
                    HStack {
                        Text(p.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Formatters.compactTokens(p.tokens))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.secondary)
                    }
                }
                if stats.todayProjects.isEmpty {
                    Text("No sessions today").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
            }
            .frame(width: 128, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Spacer()
            Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
    }

    private func money(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }
}

/// One cell per day, a column per week, today in the bottom-right corner.
private struct Heatmap: View {
    var days: [DayRecord]
    static let cell: CGFloat = 8
    static let gap: CGFloat = 2
    static let weeks = 26
    static var width: CGFloat { CGFloat(weeks) * (cell + gap) - gap }

    var body: some View {
        let levels = Self.levels(days)
        let columns = stride(from: 0, to: days.count, by: 7).map { Array(levels[$0..<min($0 + 7, days.count)]) }
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(columns.indices, id: \.self) { c in
                VStack(spacing: Self.gap) {
                    ForEach(columns[c].indices, id: \.self) { r in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(columns[c][r]))
                            .frame(width: Self.cell, height: Self.cell)
                    }
                }
            }
        }
    }

    /// 0 for no activity, then quartiles of the active days' tokens.
    static func levels(_ days: [DayRecord]) -> [Int] {
        let active = days.filter(\.active).map(\.tokens).sorted()
        guard !active.isEmpty else { return days.map { _ in 0 } }
        let q = [0.25, 0.5, 0.75].map { active[min(active.count - 1, Int(Double(active.count) * $0))] }
        return days.map { d in
            guard d.active else { return 0 }
            return 1 + q.filter { d.tokens > $0 }.count
        }
    }

    static func color(_ level: Int) -> Color {
        level == 0 ? Palette.track : Provider.claude.tint.opacity([0.3, 0.5, 0.75, 1.0][min(level, 4) - 1])
    }
}
