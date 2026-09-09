import AppKit

/// Both setup steps use one externally sized window; SwiftUI cannot grow it offscreen.
enum SetupPanelLayout {
    static func preferredSize(_ settings: RuntimeSettings,
                              stage: DeviceSetupModel.Stage = .choosingOutput,
                              automaticallySelectingOutput: Bool = false) -> CGSize {
        let height: CGFloat
        if stage == .choosingType {
            height = 220
        } else if stage == .choosingOutput || (stage == .applying && !automaticallySelectingOutput) {
            height = settings.setupTableHeightPt + 218
        } else {
            height = 220
        }
        return CGSize(width: settings.setupChoiceWidthPt + 24,
                      height: height)
    }

    static func frame(size: CGSize, visibleFrame: CGRect, margin: CGFloat) -> CGRect {
        let inset = min(max(0, margin), max(0, min(visibleFrame.width, visibleFrame.height) / 4))
        let bounds = visibleFrame.insetBy(dx: inset, dy: inset)
        let fitted = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        return CGRect(x: bounds.maxX - fitted.width, y: bounds.minY,
                      width: fitted.width, height: fitted.height)
    }
}

/// Interruptible frame animation. Duplicate HAL layout requests do not restart it.
@MainActor
final class SetupPanelResizer {
    private weak var panel: NSWindow?
    private var timer: Timer?
    private var targetFrame: CGRect?
    private(set) var isAnimating = false
    static let duration: TimeInterval = 0.24

    init(panel: NSWindow) { self.panel = panel }
    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
        targetFrame = nil
        isAnimating = false
    }

    func resize(to frame: CGRect, animated: Bool) {
        guard let panel else { stop(); return }
        if animated && targetFrame == frame { return }
        stop()
        targetFrame = frame
        let from = panel.frame
        guard animated, from != frame else {
            panel.setFrame(frame, display: true)
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        isAnimating = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / Self.duration)
                let eased = progress * progress * (3 - 2 * progress)
                panel.setFrame(CGRect(x: from.minX + (frame.minX - from.minX) * eased,
                                      y: from.minY + (frame.minY - from.minY) * eased,
                                      width: from.width + (frame.width - from.width) * eased,
                                      height: from.height + (frame.height - from.height) * eased), display: true)
                if progress >= 1 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.isAnimating = false
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
