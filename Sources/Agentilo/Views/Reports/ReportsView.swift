import AgentiloCore
import Charts
import SwiftUI

/// Tokens and API-price cost over a period, by project, model or agent.
struct ReportsView: View {
    var state: AppState
    @State private var range = ReportRange.month
    @State private var group = ReportGroup.project
    @State private var metric = ReportMetric.cost
    @State private var selectedDay: Date?
    @State private var sort = [KeyPathComparator(\ReportRow.tokens, order: .reverse)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let report = ReportBuilder.report(
            history: state.stats.history, days: range.days, groupBy: group, rankByCost: metric == .cost
        )
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Group by", selection: $group) {
                    ForEach(ReportGroup.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                Picker("Show", selection: $metric) {
                    ForEach(ReportMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
            }
            .labelsHidden()

            HStack(spacing: 12) {
                Tile(title: "Cost at API prices", value: "≈ \(Formatters.money(report.total.cost))",
                     change: Report.change(report.total.cost, report.previous.cost))
                Tile(title: "Tokens", value: Formatters.compactTokens(report.total.tokens),
                     change: Report.change(Double(report.total.tokens), Double(report.previous.tokens)))
                Tile(title: "Prompts", value: "\(report.total.prompts)",
                     change: Report.change(Double(report.total.prompts), Double(report.previous.prompts)))
                Tile(title: "Active days", value: "\(report.activeDays) of \(report.days)", change: nil)
            }

            chart(report)
                .frame(minHeight: 220)

            table(report)
                .frame(minHeight: 180)

            Text("Costs are what the same usage would cost at Anthropic and OpenAI API list prices; plans are not billed per token. Changes compare with the \(range.days) days before. Days recorded before Agentilo 0.4 have totals only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 680)
    }

    // MARK: Chart

    private func chart(_ report: Report) -> some View {
        let groups = seriesOrder(report)
        return Chart {
            ForEach(report.series) { p in
                BarMark(
                    x: .value("Day", p.day, unit: .day),
                    y: .value(metric.title, metric.value(p.usage))
                )
                .foregroundStyle(by: .value(group.displayName, p.group))
                .cornerRadius(2)
            }
            if let day = selectedDay.map({ Calendar.current.startOfDay(for: $0) }) {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DayTooltip(day: day, points: report.series.filter { $0.day == day }, metric: metric, order: groups)
                    }
            }
        }
        .chartForegroundStyleScale(domain: groups, range: groups.map { color($0, groups) })
        .chartXSelection(value: $selectedDay)
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel { if let n = v.as(Double.self) { Text(metric.format(n)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    /// Largest first, "Other" and "not broken down" last, so colors follow the table.
    private func seriesOrder(_ report: Report) -> [String] {
        var names = report.rows.map(\.name).filter { name in report.series.contains { $0.group == name } }
        if report.series.contains(where: { $0.group == ReportBuilder.other }) { names.append(ReportBuilder.other) }
        let tail = [ReportBuilder.other, ReportBuilder.unattributed]
        return names.filter { !tail.contains($0) } + tail.filter(names.contains)
    }

    /// Slots follow `order`; names beyond the chart's top groups share the "Other" gray.
    private func color(_ name: String, _ order: [String]) -> Color {
        if group == .provider, let p = Provider(rawValue: name) { return p.tint }
        let named = order.filter { $0 != ReportBuilder.other && $0 != ReportBuilder.unattributed }
        guard let i = named.firstIndex(of: name) else { return Color(hex: 0x898781) }
        return ReportPalette.slot(i, dark: scheme == .dark)
    }

    // MARK: Table

    private func table(_ report: Report) -> some View {
        let order = seriesOrder(report)
        return Table(report.rows.sorted(using: sort), sortOrder: $sort) {
            TableColumn(group.displayName, value: \.name) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(row.name, order)).frame(width: 7, height: 7)
                    Text(displayName(row.name)).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Tokens", value: \.tokens) { Text(Formatters.compactTokens($0.tokens)).monospacedDigit() }
                .width(80)
            TableColumn("Cost", value: \.cost) { Text($0.cost > 0 ? "≈ \(Formatters.money($0.cost))" : "–").monospacedDigit() }
                .width(80)
            TableColumn("Prompts", value: \.prompts) { row in
                Text(group == .model ? "–" : "\(row.prompts)").monospacedDigit()
            }
            .width(64)
            TableColumn("Share", value: \.share) { Text("\(Int(($0.share * 100).rounded()))%").monospacedDigit() }
                .width(56)
            TableColumn("Change") { row in
                let c = Report.change(metric.value(row.usage), metric.value(row.previous))
                Text(c.map(Formatters.change) ?? (report.previousBrokenDown ? "new" : "–"))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help(report.previousBrokenDown ? "" : "The period before was recorded without a breakdown.")
            }
            .width(64)
        }
    }

    private func displayName(_ name: String) -> String {
        group == .provider ? Provider(rawValue: name)?.displayName ?? name : name
    }
}

enum ReportRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90, halfYear = 182
    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .halfYear: "26 weeks"
        }
    }
}

enum ReportMetric: String, CaseIterable, Identifiable {
    case cost, tokens
    var id: String { rawValue }
    var title: String { self == .cost ? "Cost" : "Tokens" }
    func value(_ u: DayUsage) -> Double { self == .cost ? u.cost : Double(u.tokens) }
    func format(_ v: Double) -> String { self == .cost ? Formatters.money(v) : Formatters.compactTokens(Int(v)) }
}

/// Categorical slots 1-5 of the validated reference palette, light and dark steps.
enum ReportPalette {
    static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4]
    static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181]

    static func slot(_ i: Int, dark isDark: Bool) -> Color {
        let list = isDark ? dark : light
        return Color(hex: list[min(i, list.count - 1)])
    }
}

private struct Tile: View {
    var title: String
    var value: String
    var change: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text(change.map { "\(Formatters.change($0)) vs before" } ?? " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

private struct DayTooltip: View {
    var day: Date
    var points: [ReportPoint]
    var metric: ReportMetric
    var order: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption.weight(.semibold))
            let sorted = points.sorted { (order.firstIndex(of: $0.group) ?? 99) < (order.firstIndex(of: $1.group) ?? 99) }
            ForEach(sorted) { p in
                HStack {
                    Text(Provider(rawValue: p.group)?.displayName ?? p.group).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(metric.format(metric.value(p.usage))).monospacedDigit()
                }
                .font(.caption)
            }
            if points.isEmpty { Text("No activity").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(radius: 3))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
