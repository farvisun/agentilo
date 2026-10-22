import AgentLimitsCore
import AppKit
import SwiftUI

enum NotchPage: Equatable {
    case agents
    case account(Account)
    case stats
}

/// Live agent sessions from hooks and herdr, and the alerts they raise.
extension AppState {
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    /// Turns shorter than this finish without an alert; the user is likely still watching.
    static let doneAlertMinimum: TimeInterval = 20

    func startAgents() {
        agentLoop?.cancel()
        agentLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.herdrEnabled {
                    let list = await Task.detached(priority: .utility) { HerdrSource.list() }.value
                    if let list { self.notify(self.agents.applyHerdr(list)) }
                }
                self.agents.prune()
                // Poll faster while something is happening.
                let busy = self.agents.sessions.values.contains { $0.state == .working || $0.state.needsAttention }
                try? await Task.sleep(for: .seconds(busy ? 1.5 : 4))
            }
        }
    }

    func receive(_ event: AgentEvent) {
        notify(agents.apply(event))
    }

    private func notify(_ transitions: [AgentTransition]) {
        for t in transitions where t.from != nil && !isLookingAt(t.session) {
            let s = t.session
            let name = Self.agentName(s.agent)
            let what = s.title ?? s.project
            if t.to.needsAttention, settings.agentAttentionAlerts {
                let ask = t.to == .waitingPermission ? "\(name) asks for approval" : "\(name) needs your input"
                alerts.post(NotchAlert(
                    provider: s.provider, symbol: "hand.raised.fill", title: ask,
                    message: [what, s.detail].compactMap { $0 }.joined(separator: " · "),
                    color: Palette.amber, sound: settings.alertSound ? "Ping" : nil, duration: 6
                ))
            } else if t.to == .done, t.from == .working, t.after >= Self.doneAlertMinimum, settings.agentDoneAlerts {
                alerts.post(NotchAlert(
                    provider: s.provider, symbol: "checkmark.circle.fill", title: "\(name) finished",
                    message: "\(what) · after \(Formatters.duration(t.after))",
                    color: Palette.green, sound: settings.alertSound ? "Hero" : nil
                ))
            }
        }
    }

    /// The user is already looking at this agent: its herdr pane is focused in the frontmost terminal.
    private func isLookingAt(_ s: AgentSession) -> Bool {
        s.focused && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.ghosttyBundleID
    }

    /// Brings the agent's terminal forward, on its herdr pane when known.
    func jump(to session: AgentSession) {
        agents.acknowledge(session.id)
        let pane = session.herdr?.pane
        Task.detached(priority: .userInitiated) {
            if let pane { HerdrSource.focus(pane: pane) }
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.ghosttyBundleID).first?.activate()
            }
        }
    }

    static func agentName(_ agent: String) -> String {
        Provider(rawValue: agent)?.displayName ?? agent.prefix(1).uppercased() + agent.dropFirst()
    }
}
