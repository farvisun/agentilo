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
        HStack(spacing: 0) {
            if items.count >= 2 {
                // Nudge inward: the shape's concave top corner eats into the outer edge.
                CompactItem(state: state, account: items[0].account, window: items[0].window)
                    .padding(.leading, 6)
                    .frame(width: NotchGeometry.wing)
                Spacer().frame(width: l.notchWidth)
                CompactItem(state: state, account: items[1].account, window: items[1].window)
                    .padding(.trailing, 6)
                    .frame(width: NotchGeometry.wing)
            } else {
                let item = items.first
                Group {
                    if let provider = item?.account.provider {
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

/// Provider glyph + usage, sized for one wing.
private struct CompactItem: View {
    var state: AppState
    var account: Account
    var window: UsageWindow

    var body: some View {
        HStack(spacing: 3) {
            ProviderIcon(provider: account.provider, size: 12)
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
