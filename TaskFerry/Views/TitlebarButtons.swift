import AppKit
import SwiftUI

/// The sidebar and new reminder buttons, in the title bar beside the traffic lights. A toolbar item
/// would follow the sidebar's edge, and jump when it opens or closes.
struct TitlebarButtons: NSViewRepresentable {
    let canAddReminder: Bool
    let toggleSidebar: () -> Void
    let newReminder: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let content = Buttons(canAddReminder: canAddReminder, toggleSidebar: toggleSidebar, newReminder: newReminder)
        let coordinator = context.coordinator
        coordinator.show(content)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { coordinator.install(in: window) }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    @MainActor
    final class Coordinator {
        private var host: NSHostingView<Buttons>?
        private var accessory: NSTitlebarAccessoryViewController?

        func show(_ content: Buttons) {
            if let host {
                host.rootView = content
            } else {
                host = NSHostingView(rootView: content)
            }
        }

        func install(in window: NSWindow) {
            guard accessory == nil, let host else { return }
            host.frame.size = host.fittingSize
            let controller = NSTitlebarAccessoryViewController()
            controller.view = host
            controller.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller
        }

        func remove() {
            accessory?.removeFromParent()
            accessory = nil
        }
    }

    struct Buttons: View {
        let canAddReminder: Bool
        let toggleSidebar: () -> Void
        let newReminder: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                button("sidebar.left", label: "Toggle Sidebar", help: "Show or hide the sidebar (⌃⌘S)", action: toggleSidebar)
                button("plus", label: "New Reminder", help: "New Reminder (⌘N)", action: newReminder)
                    .disabled(!canAddReminder)
            }
            .padding(.horizontal, 6)
        }

        private func button(_ icon: String, label: LocalizedStringKey, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(help)
            .accessibilityLabel(label)
        }
    }
}
