import AppKit
import SwiftUI

/// 弹窗的全部可配置项。改这里即可，不必翻窗口代码。
@available(macOS 26.0, *)
struct PopupConfiguration {
    var content = Content()
    var glass = GlassOptions()
    var window = WindowOptions()
    var layout = LayoutOptions()

    struct Content {
        /// 气泡内显示的文字。
        var text = "测试样例"
        /// 正文字号，单位 pt。
        var fontSize: CGFloat = 16
        /// 正文字重。`.medium` 接近系统 HUD 标签。
        var fontWeight: Font.Weight = .medium
        /// 文字到玻璃左右内壁的距离。
        var paddingHorizontal: CGFloat = 26
        /// 文字到玻璃上下内壁的距离。
        var paddingVertical: CGFloat = 15
    }

    struct GlassOptions {
        /// 液态玻璃材质。`.clear` 更透、折射更明显；`.regular` 更像控件底；`.identity` 关掉玻璃便于对照。
        var kind: Kind = .clear
        /// 玻璃染色。`nil` 为系统默认，不偏向任何颜色。
        var tint: Color? = nil
        /// 是否用可交互玻璃（按压/悬停高光）。窗口点击穿透时悬停不会生效，但静止时的高光仍可能更“液态”。
        var interactive = false
        /// 玻璃裁切外形。
        var shape: ShapeKind = .capsule
        /// 强制控件活跃态。窗口本身不成为 key，用 `.key` 仍按焦点窗口画玻璃。
        var controlActiveState: ControlActiveState = .key

        enum Kind {
            /// 清透 Liquid Glass，底层内容更可见。
            case clear
            /// 常规 Liquid Glass，稍不透明，更接近系统按钮。
            case regular
            /// 无玻璃，只留下文字，用来确认不是毛玻璃兜底。
            case identity

            var value: Glass {
                switch self {
                case .clear: .clear
                case .regular: .regular
                case .identity: .identity
                }
            }
        }

        enum ShapeKind {
            /// 胶囊，两端半圆。
            case capsule
            /// 正圆，适合短状态。
            case circle
            /// 圆角矩形。`radius` 为角半径。
            case roundedRectangle(radius: CGFloat)
            /// 椭圆，随内容框拉伸。
            case ellipse
        }
    }

    struct WindowOptions {
        /// `true` 时鼠标点穿窗口，落到下层应用。
        var ignoresMouseEvents = true
        /// `false` 时窗口不能成为 key，不抢键盘焦点。
        var canBecomeKey = false
        /// `false` 时窗口不能成为 main。
        var canBecomeMain = false
        /// `true` 时不把应用带到前台（需配合 `.nonactivatingPanel`）。
        var nonactivating = true
        /// 窗口是否不透明。必须为 `false`，玻璃才能采样窗后桌面。
        var isOpaque = false
        /// 窗口底色。必须为透明，否则玻璃后面是一块实色。
        var backgroundColor: NSColor = .clear
        /// 系统窗口阴影。开了会在透明面板外一圈投下 AppKit 阴影。
        var hasShadow = true
        /// 窗口层级。`.floating` 浮在普通窗口之上，不保证盖过菜单栏或全屏保护界面。
        var level: NSWindow.Level = .floating
        /// 应用失活时是否自动隐藏。HUD 应保持 `false`。
        var hidesOnDeactivate = false
        /// `true` 时只有在真正需要时才试图成为 key。无焦点 HUD 应保持 `false`。
        var becomesKeyOnlyIfNeeded = false
        /// 加入所有 Space，换桌面仍在。
        var canJoinAllSpaces = true
        /// 作为全屏应用的附属窗口显示。
        var fullScreenAuxiliary = true
        /// 不进入 Cmd+` 窗口循环。
        var ignoresCycle = true
        /// 不随 Mission Control 挪动。
        var stationary = true
        /// `.accessory` 不出现在 Dock；`.regular` 会有图标并更容易激活。
        var activationPolicy: NSApplication.ActivationPolicy = .accessory
        /// 外观。`nil` 跟随系统，否则强制浅色 / 深色。
        var appearance: NSAppearance? = nil
    }

    struct LayoutOptions {
        /// 窗口尺寸。应大于气泡本身，给玻璃折射溢边留空。
        var panelSize = CGSize(width: 240, height: 110)
        /// 气泡外圈留白，避免玻璃高光被窗口裁切。
        var outerPadding: CGFloat = 28
        /// 相对屏幕可见区域底边的偏移。
        var bottomOffset: CGFloat = 36
    }
}
