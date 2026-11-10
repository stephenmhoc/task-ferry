import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// A key combination for the system-wide Quick Entry shortcut, in Carbon's terms.
struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// Not ⌃⌥Space, which macOS uses to switch input sources.
    static let standard = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), display: "⌃⇧Space")

    /// A shortcut from a key press, or nil when it would take over typing or another shortcut.
    /// It needs two modifiers, one of them ⌃ or ⌘: ⌘ alone, like ⌘C, belongs to every app, ⌃ alone
    /// edits text, like ⌃A, and ⌥ or ⌥⇧ types characters, like å.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let count = [NSEvent.ModifierFlags.command, .option, .control, .shift].filter(flags.contains).count
        guard count >= 2, !flags.isDisjoint(with: [.control, .command]) else { return nil }
        guard !Self.isReserved(keyCode: Int(event.keyCode), flags: flags) else { return nil }
        var modifiers = 0
        var symbols = ""
        if flags.contains(.control) { modifiers |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; symbols += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers),
                  display: symbols + Self.keyName(for: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Shortcuts macOS keeps for itself, which a hotkey would break everywhere.
    private static let reserved: [(key: Int, flags: NSEvent.ModifierFlags)] = [
        (kVK_ANSI_3, [.command, .shift]), (kVK_ANSI_4, [.command, .shift]), (kVK_ANSI_5, [.command, .shift]),
        (kVK_ANSI_6, [.command, .shift]), (kVK_ANSI_Q, [.command, .shift]), (kVK_ANSI_Q, [.command, .shift, .option]),
        (kVK_ANSI_Q, [.command, .control]), (kVK_Escape, [.command, .option]), (kVK_ANSI_F, [.command, .control]),
        (kVK_Space, [.command, .control]), (kVK_Space, [.control]), (kVK_Space, [.control, .option]),
        (kVK_Space, [.command, .option]), (kVK_Tab, [.command, .shift]), (kVK_ANSI_D, [.command, .option]),
        (kVK_ANSI_Slash, [.command, .shift]), (kVK_ANSI_A, [.command, .shift]),
        (kVK_LeftArrow, [.control]), (kVK_RightArrow, [.control]), (kVK_UpArrow, [.control]), (kVK_DownArrow, [.control]),
        (kVK_F2, [.control]), (kVK_F3, [.control]), (kVK_F8, [.control])
    ]

    private static func isReserved(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        reserved.contains { $0.key == keyCode && $0.flags == flags }
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func keyName(for event: NSEvent) -> String {
        if let name = namedKeys[Int(event.keyCode)] { return name }
        return (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// A system-wide shortcut for Quick Entry, ⌃⇧Space unless changed in Settings. It's registered
/// through Carbon, so no dependency or Accessibility permission is needed.
@MainActor
@Observable
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private static let shortcutKey = "quick-entry-hot-key"

    private(set) var shortcut: HotKeyShortcut
    /// Why the shortcut couldn't be registered, such as another app already using it.
    private(set) var registrationError: String?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    /// While a new shortcut is recorded, so pressing the current one doesn't open Quick Entry.
    @ObservationIgnored private var isPaused = false

    init(defaults: UserDefaults = TaskFerryRuntime.preferences) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) } ?? .standard
    }

    func register(action: @escaping () -> Void) {
        guard !TaskFerryRuntime.isDemo else { return }
        self.action = action
        guard hotKeyRef == nil, !isPaused else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalHotKey.shared.action?() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
        }
        let identifier = EventHotKeyID(signature: OSType(0x5446_5251), id: 1) // "TFRQ"
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status != noErr else {
            registrationError = nil
            return
        }
        hotKeyRef = nil
        if status == eventHotKeyExistsErr {
            registrationError = String(localized: "Another app is using \(shortcut.display). Choose a different shortcut.")
        } else {
            registrationError = String(localized: "macOS didn’t accept \(shortcut.display). Choose a different shortcut.")
            Diagnostics.report(.globalHotKey, step: "register", error: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registrationError = nil
    }

    /// Lets go of the shortcut while a new one is recorded, and takes it back afterwards.
    func setRecording(_ recording: Bool) {
        guard recording != isPaused else { return }
        isPaused = recording
        if recording {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            hotKeyRef = nil
        } else {
            applyPreference()
        }
    }

    /// Remembers a new shortcut and, if the shortcut is on, switches to it right away.
    func setShortcut(_ shortcut: HotKeyShortcut) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.shortcutKey)
        }
        if hotKeyRef != nil || registrationError != nil {
            unregister()
            applyPreference()
        }
    }

    /// Applies the user's Settings choice.
    func applyPreference() {
        if defaults.bool(forKey: AppPreferences.quickEntryHotKeyEnabled) {
            register { QuickEntryPanelController.shared.toggle(state: .shared) }
        } else {
            unregister()
        }
    }
}

/// Click it, then press the new shortcut. Esc, or clicking elsewhere, leaves the shortcut as it was.
struct ShortcutRecorder: View {
    let shortcut: HotKeyShortcut
    let onChange: (HotKeyShortcut) -> Void
    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording ? String(localized: "Type Shortcut") : shortcut.display)
                .frame(minWidth: 96)
        }
        .background {
            if isRecording {
                KeyCapture { event in
                    if let shortcut = HotKeyShortcut(event: event) {
                        onChange(shortcut)
                        isRecording = false
                    } else if event.keyCode == UInt16(kVK_Escape) {
                        isRecording = false
                    } else {
                        NSSound.beep()
                    }
                } onEnd: {
                    isRecording = false
                }
            }
        }
        .onChange(of: isRecording) { _, recording in GlobalHotKey.shared.setRecording(recording) }
        .onDisappear { if isRecording { GlobalHotKey.shared.setRecording(false) } }
        .help(isRecording ? "Press a key with two modifiers, one of them ⌃ or ⌘. Esc cancels." : "Choose a different shortcut")
        .accessibilityLabel("Quick Entry shortcut")
        .accessibilityValue(isRecording ? Text("Waiting for a shortcut") : Text(shortcut.display))
    }
}

/// Takes keyboard focus while a shortcut is recorded, and hands over the next key press.
private struct KeyCapture: NSViewRepresentable {
    let onKey: (NSEvent) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        view.onEnd = onEnd
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        view.onEnd = onEnd
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onEnd: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            onKey?(event)
        }

        // Shortcuts like ⌘Q arrive here instead of keyDown, and must not reach the menu.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            onKey?(event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onEnd?()
            return true
        }
    }
}
