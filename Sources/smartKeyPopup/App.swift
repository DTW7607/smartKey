import AppKit
import Combine
import SmartKey
import SwiftUI
import SmartKeyActions

enum AppRunMode {
    static var preview: Bool { CommandLine.arguments.contains("--settings-preview") }
    static var previewDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMARTKEY_PREVIEW_DIRECTORY"] ?? NSTemporaryDirectory() + "smartKey-settings-preview", isDirectory: true)
    }
}

@main
enum SmartKeyPopupApp {
    static func main() {
        guard #available(macOS 26.0, *) else {
            fputs("smartKey 需要 macOS 26 或更高版本\n", stderr)
            exit(1)
        }
        guard AppRunMode.preview || SingleInstance.acquire() else {
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
    let mask = RuntimeConfiguration.load(url: AppRunMode.preview ? AppRunMode.previewDirectory.appendingPathComponent("smartKey.conf") : nil)
    private var actions: ActionCoordinator?
    private var settingsWindow: SettingsWindowController?
    private var actionCancellables = Set<AnyCancellable>()
    private var executionBubbles: [UUID: GestureBubble] = [:]
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
    private lazy var setup = DeviceSetupModel(backend: service, timing: mask.setupTiming,
                                              choiceStore: DeviceChoiceStore())
    private var setupPanel: PopupPanel!
    private var setupTimer: Timer?
    private var settingsOpen = false
    private var insertionReleaseWork: DispatchWorkItem?
    private var insertionFinishWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        if AppRunMode.preview {
            createActionSystem()
            actions?.deviceStatus = "设置预览 · 不连接硬件"
            settingsWindow?.open()
            return
        }
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
            systemSymbolName: "record.circle",
            accessibilityDescription: "智键"
        )
        status.button?.image?.isTemplate = true
        status.button?.toolTip = "智键 · 3.5 mm 线控"
        LoginItem.registerIfNeeded()
        installStatusMenu()
        refreshMenu()
        createActionSystem()

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { AppRunMode.preview }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard actions?.dispatcher.runningTasks.isEmpty == false else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "还有动作正在运行"
        alert.informativeText = "停止任务后退出，或返回继续运行。"
        if actions?.dispatcher.runningTasks.contains(where: { $0.action.typeID == "shortcut" }) == true {
            alert.informativeText += "快捷指令仅停止等待，可能仍在系统中运行。"
        }
        alert.addButton(withTitle: "取消退出"); alert.addButton(withTitle: "停止任务并退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        actions?.dispatcher.cancelAll()
        Task { @MainActor [weak self] in
            for _ in 0..<120 {
                if self?.actions?.dispatcher.runningTasks.isEmpty != false { sender.reply(toApplicationShouldTerminate: true); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.actions?.notice = "任务仍在停止，请稍后再退出。"
            sender.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        setupTimer?.invalidate()
        cancelInsertionAnimation()
        service.stop()
    }

    private func createActionSystem() {
        do {
            let directory = AppRunMode.preview ? AppRunMode.previewDirectory : RuntimeConfiguration.userFile().deletingLastPathComponent()
            let actions = try ActionCoordinator(configuration: mask, directory: directory)
            self.actions = actions
            settingsWindow = SettingsWindowController(coordinator: actions)
            settingsWindow?.onOpen = { [weak self] in self?.settingsOpen = true; self?.layoutSetup() }
            settingsWindow?.onClose = { [weak self] in self?.settingsOpen = false; self?.layoutSetup() }
            if !AppRunMode.preview {
                actions.onChooseAudioDevice = { [weak self] in
                    self?.setup.chooseAudioDevice(); self?.layoutSetup(); self?.refreshMenu()
                }
                actions.onChooseSmartKey = { [weak self] in
                    self?.setup.chooseSmartKey(); self?.layoutSetup(); self?.refreshMenu()
                }
            }
            actions.onBindingsChanged = { [weak self] in self?.applySmartKeyTiming(); self?.refreshMenu() }
            actions.onFeedback = { [weak self] execution in self?.showExecution(execution) }
            actions.$isSuspended.sink { [weak self] suspended in if suspended { self?.service.resetPendingGesture() } }.store(in: &actionCancellables)
            refreshMenu()
        } catch {
            let alert = NSAlert(); alert.messageText = "动作配置无法载入"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好"); alert.runModal()
        }
    }

    private func startSmartKey() {
        service.onGestureSessionStart = { [weak self] in self?.actions?.beginSession() }
        service.onGestureSessionEnd = { [weak self] in self?.actions?.endSession() }
        setup.onStageChange = { [weak self] in
            guard let self else { return }
            self.press.pressed = false
            self.dismissGestureBubble()
            self.layoutSetup()
            self.refreshMenu()
        }
        setup.onInsertion = { [weak self] in
            self?.animateInsertion()
            if self?.settingsOpen == true {
                UserDefaults.standard.set(SettingsSection.general.rawValue, forKey: "smartKey.settings.section")
            }
        }
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
        service.onOutputGuardRestoreFailed = { [weak self] _ in
            self?.applyOnMain { delegate in
                delegate.setup.outputGuardRestoreFailed(delegate.service.audio)
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
            MainActor.assumeIsolated {
                self?.setup.tick()
                self?.publishSetup()
            }
        }
        setupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applySmartKeyTiming() {
        let doubleMs = max(Int(mask.doubleClickMs.rounded()), 1)
        let longMs = max(Int(mask.longPressMs.rounded()), 1)
        let wantDouble = actions?.store.document.doubleClickEnabled ?? false
        var next = service.configuration
        let hasDouble = next.enabledEvents.contains(.doubleClick)
        guard next.doubleClickMs != doubleMs || next.longPressMs != longMs || hasDouble != wantDouble else { return }
        next.doubleClickMs = doubleMs
        next.longPressMs = longMs
        if wantDouble {
            next.enabledEvents.insert(.doubleClick)
        } else {
            next.enabledEvents.remove(.doubleClick)
        }
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
        let slot: GestureSlot
        switch event.gesture { case .singleClick: slot = .singleClick; case .doubleClick: slot = .doubleClick; case .longPress: slot = .longPress }
        actions?.runPhysical(slot)
    }

    private func showExecution(_ execution: ActionExecution) {
        guard !AppRunMode.preview, actions?.isSuspended == false, execution.state == .running else { return }
        if executionBubbles[execution.id] != nil { return }
        guard let screen = currentScreen() else { return }
        let window = config.window
        var style: NSWindow.StyleMask = [.borderless]
        if window.nonactivating { style.insert(.nonactivatingPanel) }
        let overlay = makeOverlay(
            rect: NSRect(origin: .zero, size: config.layout.panelSize),
            style: style, window: window)
        let bubble = GestureBubble(panel: overlay, config: config, mask: mask, text: execution.action.name)
        executionBubbles[execution.id] = bubble
        bubbles.append(bubble)
        bubble.start(on: screen) { [weak self, weak bubble] in
            guard let self, let bubble else { return }
            self.bubbles.removeAll { $0 === bubble }
            self.executionBubbles.removeValue(forKey: execution.id)
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
        case login = 3
        case pause = 4
    }

    private func installStatusMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = true
        header.isHidden = false
        header.target = nil
        header.action = nil
        header.tag = MenuTag.header.rawValue
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), key: ","))
        let pause = item("暂停动作", #selector(toggleActions)); pause.tag = MenuTag.pause.rawValue; menu.addItem(pause)
        let login = item("登录时打开", #selector(toggleLoginItem))
        login.tag = MenuTag.login.rawValue
        menu.addItem(login)
        menu.addItem(item("退出", #selector(quit), key: "q"))
        status.menu = menu
    }

    private func installApplicationMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "智键")
        appMenu.addItem(item("设置…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator()); appMenu.addItem(item("退出智键", #selector(quit), key: "q"))
        appItem.submenu = appMenu; bar.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu; bar.addItem(editItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu; bar.addItem(windowItem)
        NSApp.mainMenu = bar
    }

    private func refreshMenu() {
        publishSetup()
        actions?.deviceStatus = AppRunMode.preview ? "等待连接" : connectionLabel
        actions?.deviceConnected = !AppRunMode.preview && setup.stage != .disconnected
        guard let menu = status?.menu else { return }
        if let pause = menu.item(withTag: MenuTag.pause.rawValue) { pause.title = actions?.store.document.paused == true ? "恢复动作" : "暂停动作"; pause.isEnabled = actions != nil }
        if let header = menu.item(withTag: MenuTag.header.rawValue) {
            let title = AppRunMode.preview ? "等待连接" : connectionLabel
            header.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuFont(ofSize: 0),
            ])
            header.isEnabled = true
            menu.itemChanged(header)
        }
        if let login = menu.item(withTag: MenuTag.login.rawValue) {
            login.state = LoginItem.isEnabled ? .on : .off
            menu.itemChanged(login)
        }
    }

    private var connectionLabel: String {
        switch setup.stage {
        case .disconnected, .choosingType, .paused: return "等待连接"
        case .audioDevice, .applyingAudio, .audioError: return "音频设备"
        case .choosingOutput, .applying, .activating, .active, .remoteError: return "智键"
        }
    }

    private func publishSetup() {
        guard let actions else { return }
        if actions.remainingSeconds != setup.remainingSeconds { actions.remainingSeconds = setup.remainingSeconds }
        if actions.hasAutomaticChoice != setup.hasAutomaticChoice { actions.hasAutomaticChoice = setup.hasAutomaticChoice }
        if actions.preferredChoice != setup.preferredChoice { actions.preferredChoice = setup.preferredChoice }
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
        if settingsOpen || !setup.isPresented {
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
        executionBubbles.removeAll()
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
        actions?.refresh()
        bubbles.forEach { $0.applyFocusAppearance() }
    }

    @objc private func screensChanged() {
        dismissGestureBubble()
        layout()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(sender.state != .on)
        refreshMenu()
    }

    @objc private func openSettings() { if settingsWindow == nil { createActionSystem() }; settingsWindow?.open() }
    @objc private func toggleActions() { if let actions { actions.setPaused(!actions.store.document.paused) }; refreshMenu() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
