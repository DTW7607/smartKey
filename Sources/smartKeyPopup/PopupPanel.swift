import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
    var allowsKey = false
    var allowsMain = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsMain }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Compatibility hook for existing bubble callers.
    ///
    /// AppKit owns a window's active appearance. The bubble is a nonactivating
    /// panel, so this method intentionally does not try to make it look key or
    /// send a synthetic key-state notification through private selectors.
    func applyFocusAppearance() {
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
