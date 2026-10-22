import AgentLimitsCore
import SwiftUI

/// Every running agent: what it is doing, what it waits for. Click a row to jump to its pane.
struct AgentsPage: View {
    var state: AppState

    var body: some View {
        let sessions = state.agents.ordered
        VStack(alignment: .leading, spacing: 8) {
            header(sessions)
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(sessions) { s in
                            AgentRow(session: s, now: ctx.date) { state.jump(to: s) }
                        }
                    }
                }
            }
        }
    }

    private func header(_ sessions: [AgentSession]) -> some View {
        let waiting = sessions.filter(\.state.needsAttention).count
        let working = sessions.filter { $0.state == .working }.count
        return HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.secondary)
            Text("Agents")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            if waiting > 0 {
                Text("\(waiting) waiting").foregroundStyle(Palette.amber)
            }
            if working > 0 {
                Text("\(working) working").foregroundStyle(Palette.green)
            }
            Text("\(sessions.count) total").foregroundStyle(Palette.tertiary)
        }
        .font(.system(size: 10, weight: .semibold))
    }
}

private struct AgentRow: View {
    var session: AgentSession
    var now: Date
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let p = session.provider {
                        ProviderIcon(provider: p, size: 15)
                    } else {
                        Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title ?? session.project)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                StateChip(state: session.state)
                Text(Formatters.duration(now.timeIntervalSince(session.stateSince)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Palette.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var subtitle: String {
        var parts = [session.project]
        if let tool = session.tool, session.state == .working || session.state == .waitingPermission { parts.append(tool) }
        if let detail = session.detail, session.state != .idle { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

private struct StateChip: View {
    var state: AgentState

    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .waitingPermission: ("Approval", Palette.amber)
        case .waitingInput: ("Needs input", Palette.amber)
        case .working: ("Working", Palette.green)
        case .done: ("Done", Color(red: 0.55, green: 0.75, blue: 1.0))
        case .idle: ("Idle", Palette.tertiary)
        }
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}
