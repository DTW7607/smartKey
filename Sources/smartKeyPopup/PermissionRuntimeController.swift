import Foundation

/// Keeps the resident runtime tied to authorization, while allowing permission
/// and settings windows to run without starting a resident menu-bar session.
@MainActor
final class PermissionRuntimeController {
    private(set) var isRunning = false
    private(set) var isTerminating = false
    private let start: () -> Void
    private let stop: () -> Void
    private let showRestrictedWindow: () -> Void
    private let terminate: () -> Void

    init(start: @escaping () -> Void, stop: @escaping () -> Void,
         showRestrictedWindow: @escaping () -> Void, terminate: @escaping () -> Void) {
        self.start = start
        self.stop = stop
        self.showRestrictedWindow = showRestrictedWindow
        self.terminate = terminate
    }

    func update(authorized: Bool, hasVisibleWindow: Bool) {
        guard !isTerminating, authorized != isRunning else { return }
        isRunning = authorized
        if authorized {
            start()
        } else {
            stop()
            if !hasVisibleWindow { showRestrictedWindow() }
        }
    }

    func windowClosed(authorized: Bool, hasVisibleWindow: Bool) {
        guard !isTerminating else { return }
        if authorized {
            update(authorized: true, hasVisibleWindow: hasVisibleWindow)
        } else if !hasVisibleWindow {
            shutdown()
            terminate()
        } else {
            update(authorized: false, hasVisibleWindow: true)
        }
    }

    func shutdown() {
        isTerminating = true
        if isRunning {
            isRunning = false
            stop()
        }
    }
}
