import AgentLimitsCore
import SwiftUI

struct NotchRootView: View {
    @Bindable var state: AppState
    var openSettings: () -> Void

    var body: some View {
        let l = state.layout
        let size = state.expanded ? NotchGeometry.expandedSize(l) : NotchGeometry.collapsedSize(l)
        let shape = NotchShape(topRadius: state.expanded ? 10 : 6, bottomRadius: state.expanded ? 26 : 10)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if state.expanded {
                    ExpandedView(state: state, openSettings: openSettings)
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    PillView(state: state)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            // Clip only the content; the shadow below must spill outside the shape.
            .clipShape(shape)
            .background {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(state.expanded ? 0.5 : 0), radius: 18, y: 8)
                    .shadow(color: .black.opacity(state.expanded ? 0.25 : 0), radius: 3, y: 1)
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
