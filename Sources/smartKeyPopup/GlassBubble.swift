import AppKit
import SwiftUI

@available(macOS 26.0, *)
enum GlassBubble {
    static func make(config: PopupConfiguration, content: BubbleContent) -> NSView {
        let host = TransparentHostingView(rootView: BubbleLabel(config: config, content: content))
        let inner = NSSize(
            width: config.layout.panelSize.width - config.layout.outerPadding * 2,
            height: config.layout.panelSize.height - config.layout.outerPadding * 2
        )
        let outer = config.layout.outerPadding
        let root = TransparentView(frame: NSRect(origin: .zero, size: config.layout.panelSize))
        let contentFrame = NSRect(
            origin: NSPoint(
                x: root.bounds.width - inner.width - outer,
                y: outer
            ),
            size: inner
        )

        let glassStyle: NSGlassEffectView.Style?
        switch config.glass.kind {
        case .clear:
            glassStyle = .clear
        case .regular:
            glassStyle = .regular
        case .identity:
            glassStyle = nil
        }

        if let glassStyle {
            let glass = NSGlassEffectView(frame: contentFrame)
            glass.style = glassStyle
            glass.tintColor = config.glass.tint.map { NSColor($0) }
            glass.cornerRadius = cornerRadius(config.glass.shape, size: inner)
            host.frame = glass.bounds
            host.autoresizingMask = [.width, .height]
            glass.contentView = host
            root.addSubview(glass)
        } else {
            // Keep the configured no-material option without adding a glass view.
            host.frame = contentFrame
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
        }
        return root
    }

    private static func cornerRadius(_ shape: PopupConfiguration.GlassOptions.ShapeKind, size: NSSize) -> CGFloat {
        switch shape {
        case .capsule, .circle, .ellipse:
            return min(size.width, size.height) / 2
        case .roundedRectangle(let radius):
            return radius
        }
    }
}
