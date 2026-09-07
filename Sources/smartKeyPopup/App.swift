import AppKit
import Combine
import SmartKey
import SwiftUI

@main
enum SmartKeyPopupApp {
    static func main() {
        guard #available(macOS 26.0, *) else {
            fputs("smartKey 需要 macOS 26 或更高版本\n", stderr)
            exit(1)
        }
        guard SingleInstance.acquire() else {
            fputs("智键已在运行\n", stderr)
            exit(0)
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
    let mask = RuntimeConfiguration.load()
    private let service = SmartKeyService(
        configuration: SmartKeyConfiguration(
            emitJackOnStart: true,
            enabledEvents: [.press, .release, .singleClick, .longPress, .jack]
        )
    )
    private var maskPanel: PopupPanel!
    private var maskCancellable: AnyCancellable?
    private var status: NSStatusItem!
    private var bubbles: [GestureBubble] = []
    private var nextGestureAt: TimeInterval = 0
    private lazy var setup = DeviceSetupModel(backend: service, timing: mask.setupTiming,
                                              choiceStore: DeviceChoiceStore())
    private var setupPanel: PopupPanel!
    private var setupTimer: Timer?
    private var insertionReleaseWork: DispatchWorkItem?
    private var insertionFinishWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = config.window
        var style: NSWindow.StyleMask = [.borderless]
        if window.nonactivating { style.insert(.nonactivatingPanel) }

        maskPanel = makeOverlay(rect: NSRect(origin: .zero, size: mask.overlaySize), style: style, window: window)
        maskPanel.hasShadow = false
        maskPanel.level = .screenSaver
        maskPanel.contentView = TransparentHostingView(rootView: PressMaskView(state: press, mask: mask))
        setupPanel = makeOverlay(rect: .zero, style: [.borderless, .nonactivatingPanel], window: window)
        setupPanel.allowsKey = true
        setupPanel.ignoresMouseEvents = false
        setupPanel.level = .floating
        setupPanel.contentView = TransparentHostingView(rootView: DeviceSetupView(model: setup, configuration: mask))
        maskCancellable = mask.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.layout()
                self?.applySmartKeyTiming()
                if let self { self.setup.timing = self.mask.setupTiming }
            }
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(
            systemSymbolName: "button.programmable",
            accessibilityDescription: "智键"
        )
        status.button?.toolTip = "智键 · 3.5 mm 线控"
        LoginItem.registerIfNeeded()
        installStatusMenu()
        refreshMenu()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(reapplyFocusAppearance),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(reapplyFocusAppearance),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        layout()
        startSmartKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        setupTimer?.invalidate()
        cancelInsertionAnimation()
        service.stop()
    }

    private func startSmartKey() {
        setup.onStageChange = { [weak self] in
            guard let self else { return }
            self.press.pressed = false
            self.dismissGestureBubble()
            self.layoutSetup()
            self.refreshMenu()
        }
        setup.onInsertion = { [weak self] in self?.animateInsertion() }
        service.onJackChange = { [weak self] connected in
            self?.applyOnMain { delegate in
                if !connected { delegate.cancelInsertionAnimation() }
                delegate.setup.jackChanged(connected)
            }
        }
        service.onAudioChange = { [weak self] _ in
            self?.applyOnMain { delegate in
                // HAL callbacks are queued; validate against the current route,
                // not an older snapshot captured before the user's selection.
                delegate.setup.audioChanged(delegate.service.audio)
                delegate.layoutSetup()
            }
        }
        service.onButton = { [weak self] phase in
            self?.applyOnMain { delegate in
                guard delegate.setup.acceptsButtons else { return }
                delegate.press.pressed = phase == .pressed
            }
        }
        service.onGesture = { [weak self] event in
            self?.applyOnMain { delegate in
                delegate.handleGesture(event)
            }
        }
        service.onSeizeStatusChange = { [weak self] status in
            self?.applyOnMain { delegate in
                delegate.setup.seizeChanged(status)
                delegate.refreshMenu()
            }
        }
        applySmartKeyTiming()
        setup.audioChanged(service.audio)
        service.start()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.setup.tick() }
        }
        setupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applySmartKeyTiming() {
        let doubleMs = max(Int(mask.doubleClickMs.rounded()), 1)
        let longMs = max(Int(mask.longPressMs.rounded()), 1)
        var next = service.configuration
        guard next.doubleClickMs != doubleMs || next.longPressMs != longMs else { return }
        next.doubleClickMs = doubleMs
        next.longPressMs = longMs
        service.configuration = next
    }

    private func applyOnMain(_ body: @escaping (PopupDelegate) -> Void) {
        if Thread.isMainThread {
            body(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                body(self)
            }
        }
    }

    private func handleGesture(_ event: SmartKeyGestureEvent) {
        guard setup.acceptsButtons else { return }
        let now = CACurrentMediaTime()
        guard now >= nextGestureAt else { return }
        let text: String
        switch event.gesture {
        case .singleClick:
            text = "点击事件"
        case .longPress:
            text = "长按事件"
        case .doubleClick:
            return
        }
        guard let screen = currentScreen() else { return }
        let hold = max(mask.bubbleHoldMs, 0) / 1000
        let disappear = max(mask.bubbleDisappearMs, 1) / 1000
        nextGestureAt = now + hold + disappear + mask.bubbleRetractCooldownMs / 1000
        let window = config.window
        var style: NSWindow.StyleMask = [.borderless]
        if window.nonactivating { style.insert(.nonactivatingPanel) }
        let overlay = makeOverlay(
            rect: NSRect(origin: .zero, size: config.layout.panelSize),
            style: style, window: window)
        let bubble = GestureBubble(panel: overlay, config: config, mask: mask, text: text)
        bubbles.append(bubble)
        bubble.start(on: screen) { [weak self, weak bubble] in
            guard let self, let bubble else { return }
            self.bubbles.removeAll { $0 === bubble }
        }
    }

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

    private enum MenuTag: Int {
        case header = 1
        case reconfigure = 2
        case login = 3
    }

    private func installStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = MenuTag.header.rawValue
        menu.addItem(header)
        let reconfigure = item("重新配置设备…", #selector(reconfigureDevice))
        reconfigure.tag = MenuTag.reconfigure.rawValue
        menu.addItem(reconfigure)
        menu.addItem(.separator())
        if LoginItem.isAvailable {
            let login = item("登录时打开", #selector(toggleLoginItem))
            login.tag = MenuTag.login.rawValue
            menu.addItem(login)
        }
        menu.addItem(item("退出", #selector(quit), key: "q"))
        status.menu = menu
    }

    private func refreshMenu() {
        guard let menu = status.menu else { return }
        if let header = menu.item(withTag: MenuTag.header.rawValue) {
            header.title = "智键 · \(setupMenuText)"
            menu.itemChanged(header)
        }
        if let reconfigure = menu.item(withTag: MenuTag.reconfigure.rawValue) {
            let connected = setup.stage != .disconnected
            reconfigure.isHidden = !connected
            reconfigure.isEnabled = connected
            menu.itemChanged(reconfigure)
        }
        if let login = menu.item(withTag: MenuTag.login.rawValue) {
            login.state = LoginItem.isEnabled ? .on : .off
            menu.itemChanged(login)
        }
    }

    private var setupMenuText: String {
        switch setup.stage {
        case .disconnected: return "等待 3.5 mm 设备"
        case .choosingType: return "请选择设备类型"
        case .audioDevice: return "音频设备模式"
        case .choosingOutput: return setup.error == nil ? "请选择音频输出" : "配置需要处理"
        case .applying, .applyingAudio: return "正在切换音频输出"
        case .audioError: return "耳机输出切换失败"
        case .remoteError: return "线控连接需要处理"
        case .paused: return "智键已停用"
        case .activating, .active: return seizeMenuText(service.seizeStatus)
        }
    }

    private func seizeMenuText(_ status: SmartKeySeizeStatus) -> String {
        switch status {
        case .idle: return "HID 未启动"
        case .waiting: return "等待插孔设备"
        case .seized: return "已启用"
        case .failed: return "独占失败"
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func layout() {
        guard let target = currentScreen() else { return }
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
        maskPanel.orderFrontRegardless()
        layoutSetup()
    }

    private func layoutSetup() {
        guard setupPanel != nil else { return }
        guard setup.isPresented else {
            setupPanel.orderOut(nil)
            return
        }
        // Layout on the next main-loop turn so SwiftUI has consumed the new stage.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.setup.isPresented, let target = self.currentScreen() else { return }
            let size = self.setupPanel.contentView?.fittingSize ?? NSSize(width: 504, height: 360)
            let visibleFrame = target.visibleFrame
            self.setupPanel.setFrame(NSRect(
                x: max(visibleFrame.minX, visibleFrame.maxX - size.width - self.mask.setupScreenMarginPt),
                y: visibleFrame.minY + self.mask.setupScreenMarginPt,
                width: size.width, height: size.height
            ), display: true)
            self.setupPanel.orderFrontRegardless()
        }
    }

    private func animateInsertion() {
        cancelInsertionAnimation()
        let timing = mask.insertionAnimation
        guard timing.duration > 0 else { return }
        press.insertionTiming = timing
        press.insertionAnimation = true
        press.insertionPressed = true
        maskPanel.orderFrontRegardless()
        let release = DispatchWorkItem { [weak self] in self?.press.insertionPressed = false }
        insertionReleaseWork = release
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.releaseAfter, execute: release)
        let finish = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.press.insertionAnimation = false
        }
        insertionFinishWork = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.duration, execute: finish)
    }

    private func cancelInsertionAnimation() {
        insertionReleaseWork?.cancel()
        insertionFinishWork?.cancel()
        press.insertionPressed = false
        press.insertionAnimation = false
    }

    private func dismissGestureBubble() {
        nextGestureAt = 0
        let live = bubbles
        bubbles.removeAll()
        live.forEach { $0.dismiss() }
    }

    private func currentScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let displays = screens.compactMap { screen -> DisplayPlacement.Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayPlacement.Display(id: id.uint32Value,
                builtIn: CGDisplayIsBuiltin(id.uint32Value) != 0,
                active: CGDisplayIsActive(id.uint32Value) != 0)
        }
        let preferred = DisplayPlacement.preferredID(displays, mainID: CGMainDisplayID())
        return screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == preferred
        } ?? screens.first
    }

    @objc private func reapplyFocusAppearance() {
        bubbles.forEach { $0.applyFocusAppearance() }
    }

    @objc private func screensChanged() {
        dismissGestureBubble()
        layout()
    }

    @objc private func reconfigureDevice() {
        setup.reopen()
        layoutSetup()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(sender.state != .on)
        refreshMenu()
    }

    @objc private func quit() {
        dismissGestureBubble()
        service.stop()
        NSApp.terminate(nil)
    }
}
