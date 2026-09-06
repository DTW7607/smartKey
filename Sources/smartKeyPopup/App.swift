import AppKit
import Combine
import SwiftUI

@main
enum SmartKeyPopupApp {
    static func main() {
        guard #available(macOS 26.0, *) else {
            fputs("smartKeyPopup 需要 macOS 26 或更高版本\n", stderr)
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = PopupDelegate()
        app.setActivationPolicy(delegate.config.window.activationPolicy)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@available(macOS 26.0, *)
@MainActor
final class PopupDelegate: NSObject, NSApplicationDelegate {
    let config = PopupConfiguration()
    let press = PressState()
    let mask = MaskConfig.load()
    private var panel: PopupPanel!
    private var maskPanel: PopupPanel!
    private var maskCancellable: AnyCancellable?
    private var hintWindow: NSWindow!
    private var status: NSStatusItem!
    private var visible = true
    private var screen: NSScreen?
    private var spaceMonitor: Any?
    private var bubbleHideWork: DispatchWorkItem?
    private var bubbleMotionTimer: Timer?
    private var bubbleShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = config.window
        let size = config.layout.panelSize
        var style: NSWindow.StyleMask = [.borderless]
        if window.nonactivating { style.insert(.nonactivatingPanel) }
        panel = makeOverlay(rect: NSRect(origin: .zero, size: size), style: style, window: window)
        panel.contentView = GlassBubble.make(config: config)
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

        maskPanel = makeOverlay(rect: NSRect(origin: .zero, size: mask.overlaySize), style: style, window: window)
        maskPanel.hasShadow = false
        maskPanel.level = .screenSaver
        maskPanel.contentView = TransparentHostingView(rootView: PressMaskView(state: press, mask: mask))
        maskCancellable = mask.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }

        hintWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        hintWindow.title = "实体键遮罩"
        hintWindow.isReleasedWhenClosed = false
        hintWindow.contentView = NSHostingView(rootView:
            SpaceHintView(state: press)
                .background(SpaceCatcher(
                    onDown: { [weak self] in self?.setPressed(true) },
                    onUp: { [weak self] in self?.setPressed(false) }
                ))
        )

        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            if event.type == .keyDown {
                if !event.isARepeat { self?.setPressed(true) }
                return nil
            }
            self?.setPressed(false)
            return nil
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(
            systemSymbolName: "camera.fill",
            accessibilityDescription: "相机弹窗"
        )
        status.button?.toolTip = "clear glass 弹窗 Demo · 无焦点、点击穿透"
        refreshMenu()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(reapplyFocusAppearance),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(reapplyFocusAppearance),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        layout()
        hintWindow.center()
        hintWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func makeOverlay(rect: NSRect, style: NSWindow.StyleMask, window: PopupConfiguration.WindowOptions) -> PopupPanel {
        let overlay = PopupPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        overlay.allowsKey = window.canBecomeKey
        overlay.allowsMain = window.canBecomeMain
        overlay.isOpaque = window.isOpaque
        overlay.backgroundColor = window.backgroundColor
        overlay.hasShadow = window.hasShadow
        overlay.level = window.level
        overlay.hidesOnDeactivate = window.hidesOnDeactivate
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.becomesKeyOnlyIfNeeded = window.becomesKeyOnlyIfNeeded
        overlay.appearance = window.appearance
        var behavior: NSWindow.CollectionBehavior = []
        if window.canJoinAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if window.fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if window.ignoresCycle { behavior.insert(.ignoresCycle) }
        if window.stationary { behavior.insert(.stationary) }
        overlay.collectionBehavior = behavior
        return overlay
    }

    private func setPressed(_ pressed: Bool) {
        press.pressed = pressed
        if pressed { showBubble() }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.addItem(header("clear glass · 无焦点弹窗"))
        menu.addItem(.separator())
        menu.addItem(item(visible ? "隐藏弹窗" : "显示弹窗", #selector(toggleVisible)))
        menu.addItem(item("移到鼠标所在屏幕", #selector(moveToMouse)))
        menu.addItem(item("显示空格测试窗", #selector(showHint)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
        status.menu = menu
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func layout() {
        let target = screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        screen = target
        guard let target else { return }
        if bubbleShown {
            panel.setFrameOrigin(bubbleRestOrigin(on: target))
        }
        let maskSize = mask.overlaySize
        maskPanel.setFrame(
            NSRect(
                x: target.frame.maxX - maskSize.width,
                y: target.frame.minY,
                width: maskSize.width,
                height: maskSize.height
            ),
            display: true
        )
        maskPanel.contentView?.layer?.contentsScale = target.backingScaleFactor
        if visible {
            if bubbleShown {
                panel.orderFrontRegardless()
                panel.applyFocusAppearance()
            }
            maskPanel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            maskPanel.orderOut(nil)
        }
    }

    private func showBubble() {
        guard visible, let screen = currentScreen() else { return }
        bubbleHideWork?.cancel()
        if !bubbleShown {
            bubbleShown = true
            animateBubble(appearing: true, on: screen)
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideBubble()
        }
        bubbleHideWork = work
        let hold = max(mask.bubbleHoldMs, 0) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    private func hideBubble() {
        guard bubbleShown, let screen = currentScreen() else { return }
        animateBubble(appearing: false, on: screen) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.bubbleShown = false
        }
    }

    private func currentScreen() -> NSScreen? {
        screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func bubbleRestOrigin(on screen: NSScreen) -> NSPoint {
        let (dockRight, dockTop) = dockRightAndTop(on: screen)
        let pad = config.layout.outerPadding
        let size = panel.frame.size
        return NSPoint(
            x: dockRight + mask.bubbleEndX - (size.width - pad),
            y: dockTop + mask.bubbleEndY - pad
        )
    }

    /// Dock 右缘与上缘。底栏：右缘=屏幕右，上缘=visibleFrame.minY。
    private func dockRightAndTop(on screen: NSScreen) -> (CGFloat, CGFloat) {
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
        let top = vis.minY
        return (right, top)
    }

    private func bubbleStartOrigin(on screen: NSScreen) -> NSPoint {
        let size = panel.frame.size
        return NSPoint(x: screen.frame.maxX, y: screen.frame.minY - size.height)
    }

    private func animateBubble(appearing: Bool, on screen: NSScreen, completion: (() -> Void)? = nil) {
        let view = panel.contentView
        view?.wantsLayer = true
        let layer = view?.layer
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = max((appearing ? mask.bubbleAppearMs : mask.bubbleDisappearMs), 1) / 1000
        let fromOrigin = appearing ? bubbleStartOrigin(on: screen) : panel.frame.origin
        let toOrigin = appearing ? bubbleRestOrigin(on: screen) : bubbleStartOrigin(on: screen)
        let fromScale: CGFloat = appearing ? 0.45 : 1
        let toScale: CGFloat = appearing ? 1 : 0.45

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if appearing {
            panel.setFrame(NSRect(origin: fromOrigin, size: panel.frame.size), display: true)
            layer?.transform = CATransform3DMakeScale(fromScale, fromScale, 1)
            layer?.opacity = 1
            panel.alphaValue = 1
        }
        CATransaction.commit()
        if appearing {
            panel.orderFrontRegardless()
            panel.applyFocusAppearance()
        }

        bubbleMotionTimer?.invalidate()
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
                if u >= 1 {
                    timer.invalidate()
                    self.bubbleMotionTimer = nil
                    self.panel.setFrameOrigin(toOrigin)
                    if !reduce {
                        self.panel.contentView?.layer?.transform = CATransform3DMakeScale(toScale, toScale, 1)
                    }
                    completion?()
                }
            }
        }
        bubbleMotionTimer = timer
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

    @objc private func reapplyFocusAppearance() {
        guard visible else { return }
        panel.applyFocusAppearance()
    }

    @objc private func screensChanged() {
        if let screen, !NSScreen.screens.contains(screen) {
            self.screen = NSScreen.main
        }
        layout()
    }

    @objc private func toggleVisible() {
        visible.toggle()
        layout()
        refreshMenu()
    }

    @objc private func moveToMouse() {
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        visible = true
        layout()
        refreshMenu()
    }

    @objc private func showHint() {
        hintWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        bubbleHideWork?.cancel()
        bubbleMotionTimer?.invalidate()
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        NSApp.terminate(nil)
    }
}
