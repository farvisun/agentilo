import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the transparent panel at the top of the screen and drives hover expand/collapse.
///
/// The panel is fixed-size and click-through while collapsed, so it never blocks the menu bar;
/// hover is detected by polling the cursor against the visible shape.
@MainActor
final class NotchWindowController {
    private let state: AppState
    private let panel: NotchPanel
    private var screen: NSScreen?
    private var pollTimer: Timer?
    private var scrollMonitor: Any?
    private var outsideSince: Date?
    private var insideSince: Date?
    private var scrollAccumulator: CGFloat = 0
    private var scrollConsumed = false

    init(state: AppState, openSettings: @escaping () -> Void) {
        self.state = state
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: NotchGeometry.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let root = NotchRootView(state: state, openSettings: openSettings)
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: NotchGeometry.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
    }

    func reposition() {
        guard let s = NotchGeometry.targetScreen() else { return }
        screen = s
        state.layout = NotchGeometry.layout(for: s)
        panel.setFrame(NotchGeometry.panelFrame(on: s), display: true)
    }

    private func poll() {
        guard let screen else { return }
        // Debug: `--preview-expanded` pins the expanded view open for screenshots.
        if CommandLine.arguments.contains("--preview-expanded") {
            setExpanded(true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let rect = NotchGeometry.hotRect(on: screen, layout: state.layout, expanded: state.expanded)
        // A little slack so the edge of the shape does not flicker.
        let inside = rect.insetBy(dx: -4, dy: -4).contains(mouse)
        let now = Date()

        if inside {
            outsideSince = nil
            if !state.expanded {
                if insideSince == nil { insideSince = now }
                if now.timeIntervalSince(insideSince!) > 0.12 { setExpanded(true) }
            }
        } else {
            insideSince = nil
            if state.expanded {
                if outsideSince == nil { outsideSince = now }
                if now.timeIntervalSince(outsideSince!) > 0.35 { setExpanded(false) }
            }
        }
    }

    private func setExpanded(_ value: Bool) {
        guard state.expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.expanded = value
        }
        panel.ignoresMouseEvents = !value
        if value {
            if state.page >= state.pageCount { state.page = 0 }
            state.expandedRefresh()
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard state.expanded else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        if event.phase == .began {
            scrollAccumulator = 0
            scrollConsumed = false
        }
        // One page per trackpad gesture; momentum events are ignored.
        guard event.momentumPhase == [], !scrollConsumed else { return }
        scrollAccumulator += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 1
        if abs(scrollAccumulator) >= threshold {
            withAnimation(.snappy) { state.movePage(scrollAccumulator > 0 ? 1 : -1) }
            scrollAccumulator = 0
            scrollConsumed = event.hasPreciseScrollingDeltas
        }
    }
}
