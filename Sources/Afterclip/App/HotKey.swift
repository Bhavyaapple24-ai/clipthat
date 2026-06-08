import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey using the Carbon Hot Key API.
///
/// We use Carbon (not an NSEvent global monitor) on purpose: `RegisterEventHotKey`
/// works globally — even while a fullscreen game is focused — and needs **no**
/// Accessibility or Input-Monitoring permission. That's exactly what a game clipper wants.
final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private let id: UInt32
    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: HotKey] = [:]
    private static var eventHandlerInstalled = false

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_ANSI_C`.
    ///   - modifiers: Carbon modifier flags, e.g. `cmdKey | optionKey`.
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        self.handler = handler
        HotKey.registry[id] = self

        HotKey.installDispatcherIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D454441 /* 'MEDA' */), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKey.registry[id] = nil
    }

    private static func installDispatcherIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.registry[hkID.id]?.handler?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
