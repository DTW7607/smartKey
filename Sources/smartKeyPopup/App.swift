import AppKit
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
    private var panel: PopupPanel!
    private var status: NSStatusItem!
    private var visible = true
    private var screen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = config.window
        let size = config.layout.panelSize
        var style: NSWindow.StyleMask = [.borderless]
        if window.nonactivating { style.insert(.nonactivatingPanel) }
        panel = PopupPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.allowsKey = window.canBecomeKey
        panel.allowsMain = window.canBecomeMain
        panel.isOpaque = window.isOpaque
        panel.backgroundColor = window.backgroundColor
        panel.hasShadow = window.hasShadow
        panel.level = window.level
        panel.hidesOnDeactivate = window.hidesOnDeactivate
        panel.ignoresMouseEvents = window.ignoresMouseEvents
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = window.becomesKeyOnlyIfNeeded
        panel.appearance = window.appearance
        var behavior: NSWindow.CollectionBehavior = []
        if window.canJoinAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if window.fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        if window.ignoresCycle { behavior.insert(.ignoresCycle) }
        if window.stationary { behavior.insert(.stationary) }
        panel.collectionBehavior = behavior
        panel.contentView = GlassBubble.make(config: config)

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.addItem(header("clear glass · 无焦点弹窗"))
        menu.addItem(.separator())
        menu.addItem(item(visible ? "隐藏弹窗" : "显示弹窗", #selector(toggleVisible)))
        menu.addItem(item("移到鼠标所在屏幕", #selector(moveToMouse)))
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
        let area = target.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.minY + config.layout.bottomOffset
        ))
        if visible {
            panel.orderFrontRegardless()
            panel.applyFocusAppearance()
        } else {
            panel.orderOut(nil)
        }
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
