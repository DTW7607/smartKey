import AppKit

/// One gesture HUD. Multiple instances can animate at once and never share timers or windows.
@available(macOS 26.0, *)
@MainActor
final class GestureBubble {
    private let panel: PopupPanel
    private let mask: RuntimeConfiguration
    private let outerPadding: CGFloat
    private var hideWork: DispatchWorkItem?
    private var motionTimer: Timer?
    private var onFinished: (() -> Void)?
    private var screen: NSScreen?
    private var isRetracting = false
    private let content: BubbleContent

    init(panel: PopupPanel, config: PopupConfiguration, mask: RuntimeConfiguration, text: String) {
        self.panel = panel
        self.mask = mask
        self.outerPadding = config.layout.outerPadding
        content = BubbleContent(text: text)
        panel.contentView = GlassBubble.make(config: config, content: content)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.alphaValue = 1
        panel.contentView?.wantsLayer = true
        if let view = panel.contentView, let layer = view.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            CATransaction.commit()
        }
    }

    func start(on screen: NSScreen, finished: @escaping () -> Void) {
        self.screen = screen
        isRetracting = false
        onFinished = finished
        animate(appearing: true, on: screen)
        let hold = max(mask.bubbleHoldMs, 0) / 1000
        let work = DispatchWorkItem { [weak self] in
            guard let self, let screen = self.screen else { return }
            self.isRetracting = true
            self.animate(appearing: false, on: screen) { [weak self] in self?.finish() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// Fly back from the current frame. No-op if already retracting or finished.
    func retract() {
        guard onFinished != nil, !isRetracting, let screen else { return }
        isRetracting = true
        hideWork?.cancel()
        hideWork = nil
        animate(appearing: false, on: screen) { [weak self] in self?.finish() }
    }

    func dismiss() {
        hideWork?.cancel()
        motionTimer?.invalidate()
        motionTimer = nil
        finish()
    }

    func applyFocusAppearance() { panel.applyFocusAppearance() }

    private func finish() {
        motionTimer?.invalidate()
        motionTimer = nil
        panel.orderOut(nil)
        let done = onFinished
        onFinished = nil
        done?()
    }

    private func restOrigin(on screen: NSScreen) -> NSPoint {
        let (dockRight, dockTop) = Self.dockRightAndTop(on: screen)
        let pad = outerPadding
        let size = panel.frame.size
        return NSPoint(
            x: dockRight + mask.bubbleEndX - (size.width - pad),
            y: dockTop + mask.bubbleEndY - pad
        )
    }

    private func startOrigin(on screen: NSScreen) -> NSPoint {
        let size = panel.frame.size
        return NSPoint(x: screen.frame.maxX, y: screen.frame.minY - size.height)
    }

    private static func dockRightAndTop(on screen: NSScreen) -> (CGFloat, CGFloat) {
        let frame = screen.frame
        let vis = screen.visibleFrame
        let right: CGFloat
        if vis.maxX < frame.maxX - 0.5 {
            right = frame.maxX
        } else if vis.minX > frame.minX + 0.5 {
            right = vis.minX
        } else {
            right = frame.maxX
        }
        return (right, vis.minY)
    }

    private func animate(appearing: Bool, on screen: NSScreen, completion: (() -> Void)? = nil) {
        let view = panel.contentView
        view?.wantsLayer = true
        let layer = view?.layer
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduce ? 0.1 : max((appearing ? mask.bubbleAppearMs : mask.bubbleDisappearMs), 1) / 1000
        let fromOrigin = reduce ? restOrigin(on: screen) : (appearing ? startOrigin(on: screen) : panel.frame.origin)
        let toOrigin = reduce ? restOrigin(on: screen) : (appearing ? restOrigin(on: screen) : startOrigin(on: screen))
        let fromScale: CGFloat
        let toScale: CGFloat
        if appearing {
            fromScale = 0.45
            toScale = 1
        } else {
            let current = layer.map { CGFloat($0.transform.m11) } ?? 1
            fromScale = current > 0 ? current : 1
            toScale = 0.45
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if appearing {
            panel.setFrame(NSRect(origin: fromOrigin, size: panel.frame.size), display: true)
            layer?.transform = reduce ? CATransform3DIdentity : CATransform3DMakeScale(fromScale, fromScale, 1)
            layer?.opacity = 1
            panel.alphaValue = 1
        }
        CATransaction.commit()
        if appearing {
            panel.orderFrontRegardless()
            panel.applyFocusAppearance()
        }

        motionTimer?.invalidate()
        let t0 = CACurrentMediaTime()
        let dx = toOrigin.x - fromOrigin.x
        let dy = toOrigin.y - fromOrigin.y
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let u = min(1, (CACurrentMediaTime() - t0) / duration)
                let e = appearing ? Self.easeOut(u) : Self.easeIn(u)
                self.panel.setFrameOrigin(NSPoint(x: fromOrigin.x + dx * e, y: fromOrigin.y + dy * e))
                if !reduce, let layer = self.panel.contentView?.layer {
                    let s = fromScale + (toScale - fromScale) * e
                    layer.transform = CATransform3DMakeScale(s, s, 1)
                }
                if reduce { self.panel.alphaValue = appearing ? CGFloat(u) : CGFloat(1 - u) }
                if u >= 1 {
                    timer.invalidate()
                    self.motionTimer = nil
                    self.panel.setFrameOrigin(toOrigin)
                    if !reduce {
                        self.panel.contentView?.layer?.transform = CATransform3DMakeScale(toScale, toScale, 1)
                    }
                    completion?()
                }
            }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private nonisolated static func easeOut(_ t: Double) -> CGFloat {
        let x = CGFloat(min(max(t, 0), 1))
        return 1 - pow(1 - x, 3)
    }

    private nonisolated static func easeIn(_ t: Double) -> CGFloat {
        let x = CGFloat(min(max(t, 0), 1))
        return x * x * x
    }
}
