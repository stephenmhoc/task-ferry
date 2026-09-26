import AppKit
import SwiftUI

/// A floating Quick Entry panel, like Spotlight or Things' Quick Entry. It appears over whatever
/// you're doing without bringing the main window forward, and it goes away on Esc, when you click
/// elsewhere, or once the reminder is added.
@MainActor
final class QuickEntryPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickEntryPanelController()

    private var panel: QuickEntryPanel?
    private weak var originatingWindow: NSWindow?

    func toggle(state: AppState) {
        if panel?.isVisible == true {
            close()
        } else {
            show(state: state)
        }
    }

    func show(
        state: AppState,
        title: String = "",
        notes: String? = nil,
        listID: String? = nil,
        due: QuickDueOption = .today,
        restoresWorkspaceFocus: Bool? = nil
    ) {
        guard state.mode == .remote else {
            WindowRouter.shared.showMainWindow()
            return
        }
        close(restoreFocus: false)
        let invokedFromWorkspace = restoresWorkspaceFocus ?? NSApp.isActive
        if invokedFromWorkspace {
            originatingWindow = NSApp.keyWindow ?? NSApp.mainWindow
        }
        // A nonactivating panel borrows keyboard focus from another process. Avoid that
        // machinery for our own File/Dock command, where ordinary window focus is correct.
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if !invokedFromWorkspace { style.insert(.nonactivatingPanel) }
        let panel = QuickEntryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        let hostingView = NSHostingView(rootView: QuickEntryView(
            state: state,
            style: .panel,
            initialTitle: title,
            initialNotes: notes,
            initialListID: listID,
            initialDue: due,
            onFinish: { [weak self] in self?.close() }
        ))
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close(restoreFocus: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        let previous = originatingWindow
        originatingWindow = nil
        panel.close()
        panel.contentView = nil
        if restoreFocus, let previous, previous.isVisible {
            NSApp.activate()
            previous.makeMain()
            previous.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(restoreFocus: false)
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    /// Places the panel in the upper third of the screen the pointer is on, where Spotlight appears.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 2 / 3 - size.height / 2
        ))
    }
}

private final class QuickEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
