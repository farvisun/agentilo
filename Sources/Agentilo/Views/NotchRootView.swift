import AgentiloCore
import SwiftUI

struct NotchRootView: View {
    @Bindable var state: AppState
    var openSettings: () -> Void

    var body: some View {
        let l = state.layout
        let mode = state.notchMode
        let size = NotchGeometry.size(mode, l)
        let shape = switch mode {
        case .collapsed: NotchShape(topRadius: 6, bottomRadius: 10)
        case .alert: NotchShape(topRadius: 8, bottomRadius: 20)
        case .expanded: NotchShape(topRadius: 10, bottomRadius: 26)
        case .approval: NotchShape(topRadius: 10, bottomRadius: 24)
        }
        let shadow = mode == .collapsed ? 0.0 : 1.0
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if mode == .approval, let pending = state.approvals.first {
                    VStack(spacing: 0) {
                        PillView(state: state)
                        ApprovalCard(state: state, pending: pending)
                            .id(pending.id)
                            .transition(.opacity)
                    }
                    .transition(.opacity)
                } else if state.expanded {
                    ExpandedView(state: state, openSettings: openSettings)
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    VStack(spacing: 0) {
                        PillView(state: state)
                        if let alert = state.alerts.current {
                            AlertBanner(alert: alert)
                                .id(alert.id)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            // Clip only the content; the shadow below must spill outside the shape.
            .clipShape(shape)
            .background {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.5 * shadow), radius: 18, y: 8)
                    .shadow(color: .black.opacity(0.25 * shadow), radius: 3, y: 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Collapsed: one account fills both wings (provider icon left, usage right);
/// two accounts get one wing each.
struct PillView: View {
    var state: AppState

    var body: some View {
        let l = state.layout
        let items = state.pillItems
        let progress = state.settings.pillShowsAgents ? WorkProgress(state.agents) : nil
        HStack(spacing: 0) {
            if state.settings.pillMode == .rotate, let item = items.first {
                RotatingPill(state: state, current: PillEntry(account: item.account, window: item.window), progress: progress)
            } else if items.count >= 2 {
                // Nudge inward: the shape's concave top corner eats into the outer edge.
                CompactItem(state: state, account: items[0].account, window: items[0].window, progress: progress)
                    .padding(.leading, 6)
                    .frame(width: NotchGeometry.wing)
                Spacer().frame(width: l.notchWidth)
                CompactItem(state: state, account: items[1].account, window: items[1].window)
                    .padding(.trailing, 6)
                    .frame(width: NotchGeometry.wing)
            } else {
                let item = items.first
                Group {
                    if let progress {
                        AgentProgressView(progress: progress, showsTime: true)
                    } else if let provider = item?.account.provider {
                        ProviderIcon(provider: provider, size: 13)
                    }
                }
                .padding(.leading, 6)
                .frame(width: NotchGeometry.wing, alignment: .center)

                Spacer().frame(width: l.notchWidth)

                Group {
                    if let item {
                        UsageGauge(state: state, account: item.account, window: item.window, ringSize: 13)
                    } else {
                        Text("–")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.idle)
                    }
                }
                .padding(.trailing, 6)
                .frame(width: NotchGeometry.wing, alignment: .center)
            }
        }
        .frame(height: l.notchHeight)
        .overlay(alignment: .topLeading) {
            if state.agents.attentionCount > 0 {
                AttentionDot()
                    .padding(.leading, 11)
                    .padding(.top, 5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.settings.quietReason(now: state.now) != nil {
                Image(systemName: "moon.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.trailing, 11)
                    .padding(.top, 4)
                    .help("Alerts are quiet")
            }
        }
    }
}

/// Every tracked account in turn: which account on the left wing, its limit on the right.
/// A working agent keeps its spinner in place while the accounts move past it.
private struct RotatingPill: View {
    var state: AppState
    var current: PillEntry
    var progress: WorkProgress?

    var body: some View {
        let l = state.layout
        HStack(spacing: 3) {
            if let progress { AgentProgressView(progress: progress, showsTime: false) }
            carousel(travel: NotchGeometry.wing) { entry in
                HStack(spacing: 3) {
                    if progress == nil { ProviderIcon(provider: entry.account.provider, size: 13) }
                    Text(entry.account.shortTag)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.leading, 6)
        .frame(width: NotchGeometry.wing)

        Spacer().frame(width: l.notchWidth)

        carousel(travel: NotchGeometry.wing) { entry in
            HStack(spacing: 3) {
                Text(entry.window.shortTag)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.tertiary)
                UsageGauge(state: state, account: entry.account, window: entry.window, ringSize: 13)
            }
        }
        .padding(.trailing, 6)
        .frame(width: NotchGeometry.wing)
    }

    private func carousel<Item: View>(travel: CGFloat, @ViewBuilder item: @escaping (PillEntry) -> Item) -> some View {
        PillCarousel(
            swap: state.pillSwap, current: current,
            animation: state.settings.pillRotateAnimation,
            speed: min(1.5, max(0.1, state.settings.pillRotateSpeed)),
            travel: CGSize(width: travel, height: state.layout.notchHeight),
            item: item
        )
    }
}

/// Draws the current entry over the one it replaced, moved by the last swap. Both layers stay
/// in place at rest (the old one out of sight) so each swap restarts their keyframes.
private struct PillCarousel<Item: View>: View {
    var swap: PillSwap
    var current: PillEntry
    var animation: PillRotateAnimation
    var speed: TimeInterval
    var travel: CGSize
    @ViewBuilder var item: (PillEntry) -> Item
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The "move" easing: quick start, soft landing.
    private var curve: UnitCurve {
        .bezier(startControlPoint: UnitPoint(x: 0.25, y: 1), endControlPoint: UnitPoint(x: 0.5, y: 1))
    }

    var body: some View {
        ZStack {
            layer { t in -t * swap.direction } content: {
                // Never empty: the layer has to exist before the first swap to animate it.
                if let from = swap.from { item(from) } else { Color.clear }
            }
            layer { t in (1 - t) * swap.direction } content: {
                item(current)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func layer<Content: View>(
        phase: @escaping (CGFloat) -> CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shown = reduceMotion ? PillRotateAnimation.fade : animation
        return content().keyframeAnimator(initialValue: CGFloat(1), trigger: swap.count) { [travel] view, t in
            view.modifier(PillSwapEffect(animation: shown, phase: phase(t), travel: travel))
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(CGFloat(0))
                LinearKeyframe(CGFloat(1), duration: speed, timingCurve: curve)
            }
        }
    }
}

/// `phase` is 0 at rest and ±1 fully out of sight, on the side the entry enters or leaves by.
private struct PillSwapEffect: ViewModifier {
    var animation: PillRotateAnimation
    var phase: CGFloat
    var travel: CGSize

    func body(content: Content) -> some View {
        switch animation {
        case .slideHorizontal: content.offset(x: phase * travel.width)
        case .slideVertical: content.offset(y: phase * travel.height)
        case .fade: content.opacity(1 - abs(phase))
        case .scale: content.scaleEffect(1 - abs(phase) * 0.2).opacity(1 - abs(phase))
        }
    }
}

/// An agent is waiting on the user.
private struct AttentionDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Palette.amber)
            .frame(width: 6, height: 6)
            .scaleEffect(pulse ? 1.25 : 0.8)
            .opacity(pulse ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Agents working right now, for the pill: the longest-running turn sets the time.
struct WorkProgress: Equatable {
    var since: Date
    var provider: Provider?
    var count: Int

    init?(_ store: AgentSessionStore) {
        let working = store.sessions.values.filter { $0.state == .working }
        guard let first = working.min(by: { ($0.turnStartedAt ?? $0.stateSince) < ($1.turnStartedAt ?? $1.stateSince) }) else { return nil }
        since = first.turnStartedAt ?? first.stateSince
        provider = first.provider
        count = working.count
    }
}

/// A spinning arc in the agent's color, the turn time, and a count when several work at once.
private struct AgentProgressView: View {
    var progress: WorkProgress
    var showsTime: Bool

    var body: some View {
        HStack(spacing: 4) {
            Spinner(color: progress.provider?.tint ?? Palette.green)
                .frame(width: 11, height: 11)
                .overlay(alignment: .topTrailing) {
                    if progress.count > 1 {
                        Text("\(progress.count)")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 2.5)
                            .background(Capsule().fill(Color.white.opacity(0.9)))
                            .offset(x: 6, y: -5)
                    }
                }
            if showsTime {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.short(ctx.date.timeIntervalSince(progress.since)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(progress.count > 1 ? "\(progress.count) agents working" : "Agent working")
    }

    /// "12s", "4m", "1h05".
    static func short(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh%02d", s / 3600, (s % 3600) / 60)
    }
}

private struct Spinner: View {
    var color: Color
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// Provider glyph + usage, sized for one wing.
private struct CompactItem: View {
    var state: AppState
    var account: Account
    var window: UsageWindow
    var progress: WorkProgress?

    var body: some View {
        HStack(spacing: 3) {
            if let progress {
                AgentProgressView(progress: progress, showsTime: false)
            } else {
                ProviderIcon(provider: account.provider, size: 12)
            }
            UsageGauge(state: state, account: account, window: window, ringSize: 12)
        }
    }
}

/// Ring, number or both, per the pill style setting.
private struct UsageGauge: View {
    var state: AppState
    var account: Account
    var window: UsageWindow
    var ringSize: CGFloat

    var body: some View {
        let style = state.settings.pillStyle
        let pace = window.pace(now: state.now)
        let pct = state.settings.displayMode.value(window.usedPercent)
        HStack(spacing: 4) {
            if style.showsRing {
                RingView(fraction: pct / 100, color: pace.color, lineWidth: 2.4)
                    .frame(width: ringSize, height: ringSize)
            }
            if style.showsNumber {
                Text(percentText(pct, state.status(account)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pace.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private func percentText(_ value: Double, _ status: AccountStatus?) -> String {
    let approx = status?.snapshot?.source == .estimated
    return "\(approx ? "~" : "")\(Int(value.rounded()))%"
}
