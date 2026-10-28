import AgentiloCore
import SwiftUI

/// The last 7 days against the 7 before, top projects and models, and a way into the Reports window.
struct ReportsPage: View {
    var stats: TokenStats
    var openReports: () -> Void

    var body: some View {
        let projects = ReportBuilder.report(history: stats.history, days: 7, groupBy: .project)
        let models = ReportBuilder.report(history: stats.history, days: 7, groupBy: .model)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Text("≈ \(Formatters.money(projects.total.cost))")
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                ChangeLine(now: projects.total.cost, before: projects.previous.cost, what: "vs the week before")
                Text("\(Formatters.compactTokens(projects.total.tokens)) tokens")
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.top, 4)
                ChangeLine(now: Double(projects.total.tokens), before: Double(projects.previous.tokens), what: "tokens")
                Text("\(projects.total.prompts) prompts")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 4)
                Text("active \(projects.activeDays) of 7 days")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 6)
                Button(action: openReports) {
                    Label("Open Reports", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 140, alignment: .leading)

            TopList(title: "Top projects", report: projects)
            TopList(title: "Top models", report: models)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 6)
    }
}

/// "+25% vs the week before", green when lower, amber when higher.
private struct ChangeLine: View {
    var now: Double
    var before: Double
    var what: String

    var body: some View {
        if let c = Report.change(now, before) {
            Text("\(Formatters.change(c)) \(what)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(abs(c) < 0.05 ? Palette.tertiary : c > 0 ? Palette.amber : Palette.green)
        } else {
            Text("nothing the week before").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
        }
    }
}

private struct TopList: View {
    var title: String
    var report: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            // Rank and scale by what the label shows: cost when anything is priced, else tokens.
            let priced = report.total.cost > 0
            let value: (ReportRow) -> Double = { priced ? $0.cost : Double($0.tokens) }
            let rows = report.rows.sorted { value($0) > value($1) }.prefix(4)
            let top = max(rows.first.map(value) ?? 1, .leastNonzeroMagnitude)
            ForEach(Array(rows)) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(row.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(priced ? "≈ \(Formatters.money(row.cost))" : Formatters.compactTokens(row.tokens))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(Palette.track)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Palette.green.opacity(0.85))
                                    .frame(width: max(3, g.size.width * value(row) / top))
                            }
                    }
                    .frame(height: 4)
                }
            }
            if rows.isEmpty {
                Text("No activity this week").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
