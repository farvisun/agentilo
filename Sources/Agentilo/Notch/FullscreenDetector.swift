import AppKit

/// Tells whether a full-screen app currently owns a display.
///
/// macOS has no public API for this. Native full screen gets its own Space, so the current Space
/// of each display is read from the window server (`CGSCopyManagedDisplaySpaces`, type 4 is full
/// screen). Apps that cover the whole display without a Space (games, some players) are caught by
/// a window that spans the full frame, menu bar area included, which a zoomed window never does.
enum FullscreenDetector {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let fullscreenSpaceType = 4

    static func isFullscreen(_ screen: NSScreen) -> Bool {
        hasFullscreenSpace(screen) || hasCoveringWindow(screen)
    }

    private static func hasFullscreenSpace(_ screen: NSScreen) -> Bool {
        let handle = dlopen(nil, RTLD_LAZY)
        guard let mainSym = dlsym(handle, "CGSMainConnectionID"),
              let copySym = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return false }
        let main = unsafeBitCast(mainSym, to: MainConnection.self)
        let copy = unsafeBitCast(copySym, to: CopyDisplaySpaces.self)
        guard let displays = copy(main())?.takeRetainedValue() as? [[String: Any]] else { return false }

        // With "Displays have separate Spaces" off there is a single entry named "Main".
        let uuid = displayUUID(screen)
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
            ?? (displays.count == 1 ? displays.first : nil)
        let current = entry?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == fullscreenSpaceType
    }

    private static func hasCoveringWindow(_ screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Window bounds are top-left based, relative to the primary display.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.contains(target.insetBy(dx: 1, dy: 1))
        }
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
