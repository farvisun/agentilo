import AgentiloCore
import AppKit
import Observation
import SwiftUI

/// A short message that drops out of the collapsed notch and slides back.
struct NotchAlert: Identifiable, Equatable {
    let id = UUID()
    var provider: Provider?
    /// SF Symbol shown when there is no provider.
    var symbol = "bell.fill"
    var title: String
    var message: String
    /// Up to two more lines, e.g. the agent's last reply. Makes the alert taller.
    var body: String?
    var color: Color
    /// System sound name, or nil for silence.
    var sound: String?
    var duration: TimeInterval = 4.5
    /// Still shown during quiet hours (approvals, limit reached) when the user allows it.
    var urgent = false
}

/// Shows queued alerts one at a time. Alerts wait while the notch is expanded
/// (the user is already looking) or hidden for a full-screen app.
@MainActor
@Observable
final class AlertCenter {
    enum Hold { case expanded, fullscreen }

    private(set) var current: NotchAlert?
    @ObservationIgnored private var queue: [NotchAlert] = []
    @ObservationIgnored private var holds: Set<Hold> = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    /// Decides whether an alert may be shown now; quiet hours drop the rest.
    @ObservationIgnored var allows: (NotchAlert) -> Bool = { _ in true }

    func post(_ alert: NotchAlert) {
        guard allows(alert) else { return }
        queue.append(alert)
        pump()
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { current = nil }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    func hold(_ reason: Hold, _ on: Bool) {
        if on {
            holds.insert(reason)
            guard let shown = current else { return }
            dismissTask?.cancel()
            current = nil
            // Expanding over an alert reads it; a full-screen app only postpones it.
            if reason == .fullscreen { queue.insert(shown, at: 0) }
        } else if holds.remove(reason) != nil {
            pump()
        }
    }

    private func pump() {
        guard current == nil, holds.isEmpty else { return }
        // Quiet hours may have started while these waited (e.g. behind a full-screen app).
        queue.removeAll { !allows($0) }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { current = next }
        if let sound = next.sound { NSSound(named: NSSound.Name(sound))?.play() }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled, self?.current?.id == next.id else { return }
            self?.dismiss()
        }
    }
}

extension NotchAlert {
    init(_ alert: LimitAlert, sound: Bool, now: Date = Date()) {
        let color: Color
        let tone: String
        switch alert.kind {
        case .threshold(let t) where t >= 90: (color, tone) = (Palette.red, "Funk")
        case .threshold: (color, tone) = (Palette.amber, "Pop")
        case .limitReached: (color, tone) = (Palette.red, "Basso")
        case .reset: (color, tone) = (Palette.green, "Glass")
        }
        self.init(
            provider: alert.provider,
            title: alert.title,
            message: "\(alert.message(now: now)) · \(alert.accountLabel)",
            color: color,
            sound: sound ? tone : nil,
            urgent: alert.kind == .limitReached
        )
    }
}
