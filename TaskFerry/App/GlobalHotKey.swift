import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut for Quick Entry (⌃⌥Space by default), registered through Carbon so no
/// dependency or Accessibility permission is needed.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    static let displayString = "⌃⌥Space"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) {
        self.action = action
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalHotKey.shared.action?() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
        }
        let identifier = EventHotKeyID(signature: OSType(0x5446_5251), id: 1) // "TFRQ"
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    /// Applies the user's Settings choice.
    func applyPreference(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: AppPreferences.quickEntryHotKeyEnabled) {
            register { QuickEntryPanelController.shared.toggle(state: .shared) }
        } else {
            unregister()
        }
    }
}
