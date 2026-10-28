import AgentiloCore
import SwiftUI

enum Palette {
    static let green = Color(red: 0.30, green: 0.85, blue: 0.48)
    static let amber = Color(red: 1.00, green: 0.76, blue: 0.24)
    static let red = Color(red: 1.00, green: 0.36, blue: 0.33)
    static let idle = Color.white.opacity(0.35)
    static let track = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
}

extension Pace {
    var color: Color {
        switch self {
        case .unknown: Palette.secondary
        case .onTrack: Palette.green
        case .ahead: Palette.amber
        case .runsOut, .limitReached: Palette.red
        }
    }
}

extension Provider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.55, green: 0.65, blue: 1.00)
        case .cursor: Color(red: 0.75, green: 0.75, blue: 0.80)
        }
    }
}

/// Notch-like silhouette: concave ears at the top, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct RingView: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct MeterBar: View {
    var fraction: Double
    var color: Color
    /// Where usage "should" be right now; drawn as a tick.
    var expected: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(geo.size.height, geo.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0 ? 1 : 0)
                if let expected, expected > 0, expected < 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 1.5, height: geo.size.height + 4)
                        .offset(x: geo.size.width * expected - 0.75)
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

extension UsageWindow {
    /// Share of the window that has elapsed (0...1), for the "expected" tick.
    func elapsedFraction(now: Date) -> Double? {
        guard let resetsAt, let windowLength, windowLength > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-windowLength)
        return min(max(now.timeIntervalSince(start) / windowLength, 0), 1)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Color.white : Palette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
