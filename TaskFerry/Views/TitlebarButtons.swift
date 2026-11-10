import AppKit
import SwiftUI

/// The sidebar button, in the title bar beside the traffic lights. A toolbar item would follow the
/// sidebar's edge, and jump when it opens or closes.
struct TitlebarButtons: NSViewRepresentable {
    let sidebarHidden: Bool
    let toggleSidebar: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.show(Buttons(sidebarHidden: sidebarHidden, toggleSidebar: toggleSidebar))
        // The button's size never changes, so the accessory is placed once per window rather
        // than refitted on every SwiftUI update.
        guard !coordinator.isSettled else { return }
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            coordinator.install(in: window)
            coordinator.fitTitlebar()
            coordinator.holdSidebarWidth(in: window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    @MainActor
    final class Coordinator {
        private var host: NSHostingView<Buttons>?
        private var accessory: NSTitlebarAccessoryViewController?
        private var holdsSidebarWidth = false
        private var isFitted = false

        /// Installed, fitted to the title bar, and holding the sidebar's minimum width.
        var isSettled: Bool { accessory != nil && isFitted && holdsSidebarWidth }

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

        /// The view spans the title bar's full height: at its natural height it sits on the bottom
        /// edge, below the traffic lights, instead of centered beside them.
        func fitTitlebar() {
            guard let host else { return }
            // The title bar may not be laid out yet, so it's only fitted once it has a height.
            if let height = host.superview?.bounds.height, height > 0 { isFitted = true }
            let height = host.superview?.bounds.height ?? host.fittingSize.height
            let size = NSSize(width: host.fittingSize.width, height: max(height, host.fittingSize.height))
            if host.frame.size != size { host.frame = NSRect(origin: .zero, size: size) }
        }

        /// SwiftUI's column minimum doesn't stop a drag, so the split view is told directly. The
        /// button sits over the sidebar, and it can't get narrower than the end of it. Done once
        /// the split view exists; until then, the next update tries again.
        ///
        /// SwiftUI doesn't apply the column's ideal width either: a first window opens with a
        /// sidebar far too narrow for list names. So a sidebar narrower than its minimum, which a
        /// person can't have chosen, starts at the ideal width. A width they did choose is restored
        /// by the split view's autosave and left alone.
        func holdSidebarWidth(in window: NSWindow) {
            guard !holdsSidebarWidth, let host, let contentView = window.contentView,
                  let controller = Self.splitController(in: contentView),
                  let sidebar = controller.splitViewItems.first else { return }
            let buttonsEnd = host.convert(host.bounds, to: nil).maxX
            let minimum = max(SidebarWidth.minimum, buttonsEnd + 16)
            sidebar.minimumThickness = minimum
            sidebar.maximumThickness = SidebarWidth.maximum
            if !sidebar.isCollapsed, sidebar.viewController.view.frame.width < minimum {
                controller.splitView.setPosition(max(SidebarWidth.ideal, minimum), ofDividerAt: 0)
            }
            holdsSidebarWidth = true
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
            holdsSidebarWidth = false
            isFitted = false
        }
    }

    struct Buttons: View {
        let sidebarHidden: Bool
        let toggleSidebar: () -> Void

        var body: some View {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(sidebarHidden ? "Show Sidebar" : "Hide Sidebar")
            .accessibilityLabel(sidebarHidden ? "Show Sidebar" : "Hide Sidebar")
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
    }
}
