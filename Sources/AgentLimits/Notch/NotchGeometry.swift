import AppKit

/// What the notch is drawing right now.
enum NotchMode {
    case collapsed
    /// An alert hangs below the collapsed pill.
    case alert
    case expanded
}

enum NotchGeometry {
    /// Width of each "wing" the collapsed pill adds beside the notch.
    static let wing: CGFloat = 62
    static let expandedWidth: CGFloat = 580
    static let expandedContentHeight: CGFloat = 214
    static let alertWidth: CGFloat = 400
    static let alertHeight: CGFloat = 52
    /// The panel is always this big; only the drawn shape changes size.
    /// The margin around the expanded shape leaves room for its shadow.
    static let panelSize = CGSize(width: expandedWidth + 120, height: 340)

    /// Prefer the built-in display with a notch; otherwise the main screen gets a fake notch.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func layout(for screen: NSScreen) -> NotchLayout {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchLayout(notchWidth: width, notchHeight: top, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchLayout(notchWidth: 160, notchHeight: max(24, menuBar > 0 ? menuBar : 24), hasNotch: false)
    }

    static func collapsedSize(_ l: NotchLayout) -> CGSize {
        CGSize(width: l.notchWidth + wing * 2, height: l.notchHeight)
    }

    static func expandedSize(_ l: NotchLayout) -> CGSize {
        CGSize(width: max(expandedWidth, l.notchWidth + wing * 2), height: l.notchHeight + expandedContentHeight)
    }

    static func alertSize(_ l: NotchLayout) -> CGSize {
        CGSize(width: max(alertWidth, l.notchWidth + wing * 2), height: l.notchHeight + alertHeight)
    }

    static func size(_ mode: NotchMode, _ l: NotchLayout) -> CGSize {
        switch mode {
        case .collapsed: collapsedSize(l)
        case .alert: alertSize(l)
        case .expanded: expandedSize(l)
        }
    }

    /// Screen-space rect of the visible shape, centered under the notch.
    static func hotRect(on screen: NSScreen, layout l: NotchLayout, mode: NotchMode) -> CGRect {
        let size = size(mode, l)
        let midX = notchMidX(on: screen)
        return CGRect(x: midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    static func notchMidX(on screen: NSScreen) -> CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return screen.frame.minX + left.width + (screen.frame.width - left.width - right.width) / 2
        }
        return screen.frame.midX
    }

    static func panelFrame(on screen: NSScreen) -> CGRect {
        let midX = notchMidX(on: screen)
        return CGRect(
            x: midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
