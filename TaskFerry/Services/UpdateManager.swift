import Foundation
import Observation

#if SPARKLE_ENABLED
import Sparkle
#endif

/// Wraps Sparkle so the menu item and Settings can observe its state. The updater starts a few
/// seconds after launch rather than during it: nothing about updates needs to happen before the
/// first window is usable.
@MainActor
@Observable
final class UpdateManager {
    static let shared = UpdateManager()

    private(set) var canCheckForUpdates = false
    /// Until Sparkle starts, "Check for Updates…" stays enabled and starts it on demand.
    private(set) var hasStarted = false

    #if SPARKLE_ENABLED
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    #endif

    static var isSupported: Bool {
        #if SPARKLE_ENABLED
        true
        #else
        false
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.canCheckForUpdates)
            #if SPARKLE_ENABLED
            return controller?.updater.automaticallyChecksForUpdates ?? true
            #else
            return false
            #endif
        }
        set {
            #if SPARKLE_ENABLED
            start()
            withMutation(keyPath: \.canCheckForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
            #endif
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.canCheckForUpdates)
            #if SPARKLE_ENABLED
            return controller?.updater.automaticallyDownloadsUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if SPARKLE_ENABLED
            start()
            withMutation(keyPath: \.canCheckForUpdates) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
            #endif
        }
    }

    func startAfterLaunch() {
        guard Self.isSupported else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.start()
        }
    }

    func start() {
        #if SPARKLE_ENABLED
        guard controller == nil else { return }
        hasStarted = true
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        // Sparkle changes this property on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        #endif
    }

    func checkForUpdates() {
        #if SPARKLE_ENABLED
        start()
        controller?.checkForUpdates(nil)
        #endif
    }
}
