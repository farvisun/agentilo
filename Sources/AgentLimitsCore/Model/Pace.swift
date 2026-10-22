import Foundation

/// Compares usage with the share of the window that has elapsed.
public enum Pace: Equatable, Sendable {
    case unknown
    case onTrack
    case ahead
    case runsOut(Date)
    case limitReached(resetsAt: Date?)

    /// Usage may run this many points above the clock before it counts as "ahead".
    public static let tolerance: Double = 5
    /// Beyond this many points over the clock, warn with a projected run-out time.
    /// (With a linear projection any overshoot runs out before reset, so small gaps stay "ahead".)
    public static let runOutGap: Double = 12

    public static func evaluate(
        usedPercent: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        now: Date = Date()
    ) -> Pace {
        if usedPercent >= 100 { return .limitReached(resetsAt: resetsAt) }
        guard let resetsAt, let windowLength, windowLength > 0 else { return .unknown }

        let start = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = min(max(now.timeIntervalSince(start), 0), windowLength)
        guard elapsed > 0 else { return .onTrack }

        let expected = elapsed / windowLength * 100
        let gap = usedPercent - expected
        if gap <= tolerance { return .onTrack }
        if gap <= runOutGap { return .ahead }

        let ratePerSecond = usedPercent / elapsed
        let runout = now.addingTimeInterval((100 - usedPercent) / ratePerSecond)
        return runout < resetsAt ? .runsOut(runout) : .ahead
    }

    /// Higher is worse; used to pick the most critical account and window.
    public var severity: Int {
        switch self {
        case .unknown: 0
        case .onTrack: 1
        case .ahead: 2
        case .runsOut: 3
        case .limitReached: 4
        }
    }

    public func label(now: Date = Date()) -> String {
        switch self {
        case .unknown: ""
        case .onTrack: "On track"
        case .ahead: "Ahead of pace"
        case .runsOut(let date): "Runs out \(Formatters.resetTime(date, now: now))"
        case .limitReached(let reset):
            if let reset { "Limit reached · back \(Formatters.resetTime(reset, now: now))" } else { "Limit reached" }
        }
    }
}
