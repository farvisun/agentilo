import AppKit
import Carbon.HIToolbox
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the transparent panel at the top of the screen and drives expand/collapse,
/// on hover or on click depending on settings.
///
/// The panel is fixed-size and click-through while collapsed, so it never blocks the menu bar;
/// hover is detected by polling the cursor against the visible shape. In click mode the panel
/// only takes mouse events while the cursor is over the pill, and a click elsewhere collapses it.
/// The panel steps aside while an app is full screen on its display.
@MainActor
final class NotchWindowController {
    private let state: AppState
    private let panel: NotchPanel
    private var screen: NSScreen?
    private var pollTimer: Timer?
    private var fullscreenTimer: Timer?
    /// Out of the way of a full-screen app or a screen capture.
    private var steppedAside = false
    private var toggleHotKey: GlobalHotKey?
    private var escapeHotKey: GlobalHotKey?
    /// Opened with the shortcut: stays open with the cursor elsewhere, until a click outside or Esc.
    private var openedByShortcut = false {
        didSet {
            guard openedByShortcut != oldValue else { return }
            escapeHotKey?.unregister()
            escapeHotKey = nil
            if openedByShortcut {
                escapeHotKey = GlobalHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                    self?.setExpanded(false)
                }
            }
        }
    }
    /// Closed with the shortcut under the cursor: hover waits until the cursor has left.
    private var hoverSuppressed = false
    private var scrollMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        }
    }

    func show() {
        reposition()
        if !steppedAside { panel.orderFrontRegardless() }
        state.onHotKeyChange = { [weak self] in self?.applyHotKey() }
        applyHotKey()
        // Notifications miss apps that cover the display without a Space of their own.
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.handleClick() ?? false }
            return swallow ? nil : event
        }
        // Clicks in other apps never reach the local monitor; they mean "outside".
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseOnOutsideClick() }
        }
    }

    func reposition() {
        guard let s = NotchGeometry.targetScreen() else { return }
        screen = s
        state.layout = NotchGeometry.layout(for: s)
        panel.setFrame(NotchGeometry.panelFrame(on: s), display: true)
        updateVisibility()
    }

    private func applyHotKey() {
        toggleHotKey?.unregister()
        toggleHotKey = nil
        state.hotKeyRefused = false
        guard let key = state.settings.toggleHotKey else { return }
        toggleHotKey = GlobalHotKey(keyCode: key.keyCode, modifiers: key.modifiers) { [weak self] in
            self?.toggleFromShortcut()
        }
        state.hotKeyRefused = toggleHotKey == nil
    }

    private func toggleFromShortcut() {
        guard !steppedAside, state.notchMode != .approval else { return }
        if state.expanded {
            setExpanded(false)
            hoverSuppressed = true
        } else {
            setExpanded(true)
            openedByShortcut = true
        }
    }

    private func updateVisibility() {
        guard let screen else { return }
        let watch = state.settings.hideWhileCaptured || state.settings.blurNamesWhileCaptured
        let captured = watch && ScreenCaptureProbe.isCaptured
        if captured != state.screenCaptured { state.screenCaptured = captured }
        let hide = FullscreenDetector.isFullscreen(screen) || (state.settings.hideWhileCaptured && captured)
        guard hide != steppedAside else { return }
        steppedAside = hide
        state.notchHidden = hide
        state.alerts.hold(.fullscreen, hide)
        // A prompt nobody can see goes back to the terminal.
        if hide { for p in state.approvals { state.resolveApproval(p.id, .none) } }
        if hide {
            openedByShortcut = false
            state.expanded = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func poll() {
        guard let screen, !steppedAside else { return }
        // Debug: `--preview-expanded` pins the expanded view open for screenshots.
        if CommandLine.arguments.contains("--preview-expanded") {
            setExpanded(true)
            // `--preview-page last|reports|switch` opens on that page.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--preview-page"), i + 1 < args.count,
               let page = state.previewPage(args[i + 1]), state.page != page {
                state.page = page
            }
            return
        }
        let inside = isInside(NSEvent.mouseLocation, screen: screen)
        if state.notchMode == .approval {
            // The card takes clicks wherever it is drawn, in either trigger mode, and never expands.
            insideSince = nil
            outsideSince = nil
            panel.ignoresMouseEvents = !inside
            return
        }
        if state.settings.expandTrigger == .click {
            insideSince = nil
            outsideSince = nil
            // Catch clicks on the pill only; elsewhere the menu bar stays usable.
            if !state.expanded { panel.ignoresMouseEvents = !inside }
            return
        }
        let now = Date()

        if hoverSuppressed {
            if inside { return }
            hoverSuppressed = false
        }
        if inside {
            outsideSince = nil
            if !state.expanded {
                if insideSince == nil { insideSince = now }
                if now.timeIntervalSince(insideSince!) > 0.12 { setExpanded(true) }
            }
        } else {
            insideSince = nil
            if state.expanded, !openedByShortcut {
                if outsideSince == nil { outsideSince = now }
                if now.timeIntervalSince(outsideSince!) > 0.35 { setExpanded(false) }
            }
        }
    }

    private func isInside(_ point: NSPoint, screen: NSScreen) -> Bool {
        let rect = NotchGeometry.hotRect(on: screen, layout: state.layout, mode: state.notchMode)
        // A little slack so the edge of the shape does not flicker.
        return rect.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Click mode: a click on the pill expands; a click outside the shape collapses.
    /// Returns true when the click was used to expand and should not reach the views.
    private func handleClick() -> Bool {
        guard state.settings.expandTrigger == .click || openedByShortcut, state.notchMode != .approval, let screen, !steppedAside else {
            return false
        }
        let inside = isInside(NSEvent.mouseLocation, screen: screen)
        if !state.expanded, inside {
            setExpanded(true)
            return true
        }
        if state.expanded, !inside { setExpanded(false) }
        return false
    }

    private func collapseOnOutsideClick() {
        guard state.settings.expandTrigger == .click || openedByShortcut, state.expanded, state.notchMode != .approval,
              !CommandLine.arguments.contains("--preview-expanded") else { return }
        setExpanded(false)
    }

    private func setExpanded(_ value: Bool) {
        guard state.expanded != value else { return }
        if !value { openedByShortcut = false }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            state.expanded = value
        }
        panel.ignoresMouseEvents = !value
        state.alerts.hold(.expanded, value)
        if value {
            if state.page >= state.pageCount { state.page = 0 }
            state.expandedRefresh()
        }
    }

    private func handleScroll(_ event: NSEvent) {
        // The collapsed panel only gets scrolls in click mode, while the cursor is over the pill.
        let rotates = state.notchMode == .collapsed && state.settings.pillMode == .rotate
        guard state.expanded || rotates else { return }
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
            let step = scrollAccumulator > 0 ? 1 : -1
            if state.expanded {
                withAnimation(.snappy) { state.movePage(step) }
            } else {
                state.swipePill(step)
            }
            scrollAccumulator = 0
            scrollConsumed = event.hasPreciseScrollingDeltas
        }
    }
}
