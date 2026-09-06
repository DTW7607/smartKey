import AppKit
import ObjectiveC
import SwiftUI

final class PopupPanel: NSPanel {
    var allowsKey = false
    var allowsMain = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsMain }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// 不成为真正的 key window，只把绘制切到焦点外观。
    func applyFocusAppearance() {
        let acquire = NSSelectorFromString("acquireKeyAppearance")
        if responds(to: acquire) { perform(acquire) }
        setBool("_setHasActiveAppearance:", true)
        notifyGlassKeyState(contentView)
    }

    private func setBool(_ name: String, _ value: Bool) {
        let sel = NSSelectorFromString(name)
        guard responds(to: sel), let method = class_getInstanceMethod(Self.self, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(self, sel, value)
    }

    private func notifyGlassKeyState(_ view: NSView?) {
        guard let view else { return }
        let sel = NSSelectorFromString("_windowChangedKeyState")
        if view.responds(to: sel) { view.perform(sel) }
        view.subviews.forEach { notifyGlassKeyState($0) }
    }
}

final class TransparentView: NSView {
    override var isOpaque: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.allowsEdgeAntialiasing = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        layer?.allowsEdgeAntialiasing = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
