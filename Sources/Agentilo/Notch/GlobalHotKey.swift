import Carbon.HIToolbox

/// A system-wide key combination. Carbon's hot keys need no Accessibility or Input Monitoring
/// permission, and macOS still has no newer API for them.
@MainActor
final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Nil when macOS refuses the combination, usually because another app holds it.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        var hotKey: EventHotKeyRef?
        let signature = OSType(0x4147_4C4F) // "AGLO"
        let status = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(), 0, &hotKey
        )
        guard status == noErr, let hotKey else { return nil }
        ref = hotKey
        Self.actions[id] = action
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard status == noErr else { return status }
            let id = pressed.id
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &type, nil, nil)
    }
}
