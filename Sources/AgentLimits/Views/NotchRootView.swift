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

/// Collapsed: one account fills both wings (ring left, percentage right);
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
                let pace = item?.window.pace(now: state.now) ?? .unknown
                let pct = item.map { state.settings.displayMode.value($0.window.usedPercent) }
                HStack(spacing: 5) {
                    if let provider = item?.account.provider {
                        ProviderIcon(provider: provider, size: 13)
                    }
                    RingView(fraction: (pct ?? 0) / 100, color: pace.color, lineWidth: 2.4)
                        .frame(width: 13, height: 13)
                }
                .frame(width: NotchGeometry.wing, alignment: .center)

                Spacer().frame(width: l.notchWidth)

                Text(pct.map { percentText($0, item.map { state.status($0.account) }) } ?? "–")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pct == nil ? Palette.idle : pace.color)
                    .frame(width: NotchGeometry.wing, alignment: .center)
            }
        }
        .frame(height: l.notchHeight)
    }
}

/// Provider glyph + percentage, sized for one wing.
private struct CompactItem: View {
    var state: AppState
    var account: Account
    var window: UsageWindow

    var body: some View {
        let pace = window.pace(now: state.now)
        let pct = state.settings.displayMode.value(window.usedPercent)
        HStack(spacing: 3) {
            ProviderIcon(provider: account.provider, size: 12)
            Text(percentText(pct, state.status(account)))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(pace.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private func percentText(_ value: Double, _ status: AccountStatus?) -> String {
    let approx = status?.snapshot?.source == .estimated
    return "\(approx ? "~" : "")\(Int(value.rounded()))%"
}
