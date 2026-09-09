/// General settings need live device state even before Accessibility is granted.
/// Without resident authorization, that work belongs only to the visible window.
@MainActor
final class DeviceMonitoringController {
    private(set) var isRunning = false
    private let start: () -> Void
    private let stop: () -> Void

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
    }

    func update(residentAuthorized: Bool, settingsVisible: Bool) {
        let wanted = residentAuthorized || settingsVisible
        guard wanted != isRunning else { return }
        isRunning = wanted
        if wanted { start() } else { stop() }
    }
}
