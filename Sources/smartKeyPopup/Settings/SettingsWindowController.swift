import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: ActionCoordinator
    private static let windowWidth: CGFloat = 800
    init(coordinator: ActionCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "智键设置"
        window.minSize = NSSize(width: Self.windowWidth, height: 520)
        window.maxSize = NSSize(width: Self.windowWidth, height: 12_000)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SmartKeySettingsView(coordinator: coordinator))
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    func open() {
        coordinator.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        hideSidebarToggle()
        onOpen?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        coordinator.refresh()
        hideSidebarToggle()
    }
    func windowDidUpdate(_ notification: Notification) { hideSidebarToggle() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidMiniaturize(_ notification: Notification) { onMinimize?() }
    func windowDidDeminiaturize(_ notification: Notification) { onOpen?() }

    private func hideSidebarToggle() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            let raw = item.itemIdentifier.rawValue.lowercased()
            if raw.contains("sidebar") || item.itemIdentifier == .toggleSidebar {
                item.isHidden = true
            }
        }
    }
}
