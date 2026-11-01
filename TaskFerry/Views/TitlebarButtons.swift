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
            guard let window = view?.window else { return }
            coordinator.install(in: window)
            coordinator.holdSidebarWidth(in: window)
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

        /// SwiftUI's column minimum doesn't stop a drag, so the split view is told directly. The
        /// buttons sit over the sidebar, and it can't get narrower than the end of them.
        func holdSidebarWidth(in window: NSWindow) {
            guard let host, let contentView = window.contentView,
                  let sidebar = Self.splitController(in: contentView)?.splitViewItems.first else { return }
            let buttonsEnd = host.convert(host.bounds, to: nil).maxX
            sidebar.minimumThickness = max(220, buttonsEnd + 16)
        }

        private static func splitController(in view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            for subview in view.subviews {
                if let controller = splitController(in: subview) { return controller }
            }
            return nil
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
