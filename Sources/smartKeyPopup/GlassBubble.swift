import AppKit
import SwiftUI

@available(macOS 26.0, *)
enum GlassBubble {
    static func make(config: PopupConfiguration) -> NSView {
        let host = TransparentHostingView(rootView: BubbleLabel(config: config))
        let inner = NSSize(
            width: config.layout.panelSize.width - config.layout.outerPadding * 2,
            height: config.layout.panelSize.height - config.layout.outerPadding * 2
        )
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: inner))
        glass.style = .clear
        glass.cornerRadius = cornerRadius(config.glass.shape, size: inner)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.contentView = host
        enableAdaptive(glass)

        let outer = config.layout.outerPadding
        let root = TransparentView(frame: NSRect(origin: .zero, size: config.layout.panelSize))
        glass.frame.origin = NSPoint(
            x: root.bounds.width - inner.width - outer,
            y: outer
        )
        root.addSubview(glass)
        return root
    }

    /// 打开 NSGlassEffectView 按背景亮度切换亮/暗，SwiftUI 内容会跟着 effectiveAppearance 走。
    private static func enableAdaptive(_ glass: NSGlassEffectView) {
        setInt(glass, "set_adaptiveAppearance:", 2)
        setInt(glass, "set_scrimState:", 0)
        setInt(glass, "set_contentLensing:", 1)
        setInt(glass, "set_variant:", 2)
    }

    private static func setInt(_ object: NSObject, _ name: String, _ value: Int) {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let method = class_getInstanceMethod(type(of: object), sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(object, sel, value)
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
