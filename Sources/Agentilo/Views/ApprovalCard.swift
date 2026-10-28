import AgentiloCore
import SwiftUI

/// A Claude Code permission prompt, answered from the notch. When the time runs out,
/// Claude Code asks in the terminal instead.
struct ApprovalCard: View {
    var state: AppState
    var pending: PendingApproval

    var body: some View {
        let r = pending.request
        let session = state.agents.sessions[pending.sessionKey]
        let name = AppState.agentName(r.event.agent)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Group {
                    if let p = Provider(rawValue: r.event.agent) {
                        ProviderIcon(provider: p, size: 18)
                    } else {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Palette.amber)
                    }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name) wants to use \(r.event.tool ?? "a tool")")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(context(session))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if state.approvals.count > 1 {
                    Text("1 of \(state.approvals.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }

            Text(r.input ?? r.event.detail ?? "No details")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                .help(r.input ?? "")

            HStack(spacing: 6) {
                CardButton(title: "Terminal", tint: Palette.secondary, filled: false) {
                    state.answerInTerminal(pending)
                }
                .help("Answer in the terminal instead")
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let left = max(0, pending.deadline.timeIntervalSince(ctx.date))
                    let total = TimeInterval(max(5, state.settings.approvalTimeout))
                    HStack(spacing: 5) {
                        MeterBar(fraction: left / total, color: Color.white.opacity(0.35))
                            .frame(height: 3)
                        Text("\(Int(left.rounded(.up)))s")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Palette.tertiary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
                CardButton(title: "Deny", tint: Palette.red, filled: false) {
                    state.resolveApproval(pending.id, .deny)
                }
                if r.canAlwaysAllow {
                    CardButton(title: "Always", tint: Palette.green, filled: false) {
                        state.resolveApproval(pending.id, .allowAlways)
                    }
                    .help("Allow, and apply Claude Code's suggested rule so it stops asking")
                }
                CardButton(title: "Allow", tint: Palette.green, filled: true) {
                    state.resolveApproval(pending.id, .allow)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .frame(height: NotchGeometry.approvalHeight, alignment: .top)
    }

    private func context(_ s: AgentSession?) -> String {
        let project = s?.project ?? r.event.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        return [s?.title, project].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var r: ApprovalRequest { pending.request }
}

private struct CardButton: View {
    var title: String
    var tint: Color
    var filled: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filled ? Color.black : tint)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    Capsule().fill(filled ? tint.opacity(hover ? 1 : 0.88) : tint.opacity(hover ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
