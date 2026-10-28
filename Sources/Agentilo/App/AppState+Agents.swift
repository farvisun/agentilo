import AgentiloCore
import AppKit
import SwiftUI

struct PendingApproval: Identifiable, Equatable {
    var request: ApprovalRequest
    var sessionKey: String
    var deadline: Date

    var id: String { request.id }
}

enum NotchPage: Equatable {
    case agents
    case account(Account)
    case stats
    case activity
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

    func receive(_ event: AgentEvent, alert: Bool = true) {
        let transitions = agents.apply(event)
        if alert { notify(transitions) }
        // The turn moved on without us (answered in the terminal, interrupted): drop its prompt.
        if [.prompt, .postTool, .stop, .sessionEnd].contains(event.kind) {
            let key = AgentSessionStore.key(agent: event.agent, sessionID: event.sessionID, herdr: event.herdr)
            for p in approvals where p.sessionKey == key { resolveApproval(p.id, .none) }
        }
    }

    // MARK: Approvals

    /// Holds a permission prompt in the notch until the user answers or it times out.
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let transitions = agents.apply(request.event)
        let key = AgentSessionStore.key(agent: request.event.agent, sessionID: request.event.sessionID, herdr: request.event.herdr)
        // Out of sight, or the user is looking at the terminal already: let Claude Code ask there
        // without delay. Otherwise the card replaces the alert for this prompt.
        let looking = agents.sessions[key].map(isLookingAt) ?? false
        guard settings.approvalsEnabled, !notchHidden, !looking else {
            notify(transitions)
            return .none
        }

        let timeout = TimeInterval(max(5, settings.approvalTimeout))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            approvals.append(PendingApproval(request: request, sessionKey: key, deadline: Date().addingTimeInterval(timeout)))
        }
        if settings.alertSound, approvals.count == 1 { NSSound(named: "Ping")?.play() }
        return await withCheckedContinuation { c in
            approvalWaiters[request.id] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveApproval(request.id, .none)
            }
        }
    }

    func resolveApproval(_ id: String, _ decision: ApprovalDecision) {
        guard let waiter = approvalWaiters.removeValue(forKey: id) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            approvals.removeAll { $0.id == id }
        }
        waiter.resume(returning: decision)
    }

    /// "Answer in terminal": no decision from us, and show the agent's pane.
    func answerInTerminal(_ pending: PendingApproval) {
        resolveApproval(pending.id, .none)
        if let s = agents.sessions[pending.sessionKey] { jump(to: s) }
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
    func isLookingAt(_ s: AgentSession) -> Bool {
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
