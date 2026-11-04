import CoreGraphics
import Foundation

/// Tells whether the screen is being shared or recorded.
///
/// macOS has no public API for this, and `NSWindow.sharingType = .none` no longer hides windows
/// from ScreenCaptureKit since macOS 15. The window server's watcher flag, which also lights the
/// system's capture indicator, is read through `dlsym`. If a future macOS drops it, only remote
/// sessions are still noticed, from the public session dictionary.
@MainActor
enum ScreenCaptureProbe {
    private typealias IsWatcherPresent = @convention(c) () -> Bool

    private static let isWatcherPresent: IsWatcherPresent? = {
        let handle = dlopen(nil, RTLD_LAZY)
        guard let symbol = dlsym(handle, "SLSIsScreenWatcherPresent") ?? dlsym(handle, "CGSIsScreenWatcherPresent") else {
            return nil
        }
        return unsafeBitCast(symbol, to: IsWatcherPresent.self)
    }()

    static var isCaptured: Bool {
        if let isWatcherPresent { return isWatcherPresent() }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsShared"] as? Bool == true
    }
}
