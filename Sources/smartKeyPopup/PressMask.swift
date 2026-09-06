import AppKit
import Combine
import SwiftUI

final class PressState: ObservableObject {
    @Published var pressed = false
}

/// 右下角 L 形黑罩：内侧平面，远端为正圆角接负圆角贴边。
struct PressMaskView: View {
    @ObservedObject var state: PressState
    @ObservedObject var mask: MaskConfig

    var body: some View {
        let pad = mask.shadowPad
        let size = mask.shapeSize
        ZStack(alignment: .bottomTrailing) {
            CornerLMask(
                side: mask.sidePt,
                bottom: mask.bottomPt,
                radius: mask.cornerRadiusPt,
                positive: mask.positiveRadiusPt,
                negative: mask.negativeRadiusPt,
                taper: mask.taperLengthPt,
                cornerSpeed: mask.cornerSpeed,
                progress: state.pressed ? 1 : 0
            )
            .fill(Color.black)
            .shadow(color: Color.white.opacity(mask.shadowOpacity), radius: mask.shadowRadiusPt)
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width + pad, height: size.height + pad, alignment: .bottomTrailing)
        .animation(
            .easeOut(duration: (state.pressed ? mask.appearMs : mask.disappearMs) / 1000),
            value: state.pressed
        )
        .allowsHitTesting(false)
    }
}

struct CornerLMask: Shape {
    var side: CGFloat
    var bottom: CGFloat
    var radius: CGFloat
    var positive: CGFloat
    var negative: CGFloat
    var taper: CGFloat
    var cornerSpeed: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, min(progress, 1))
        let pCorner = max(0, min(1, 1 - pow(1 - p, max(cornerSpeed, 1))))
        let s = side * p
        let b = bottom * p
        let w = rect.width
        let h = rect.height
        guard s > 0.4, b > 0.4, w > s, h > b else { return Path() }
        let r = min(radius * pCorner, max(0, w - s - 1), max(0, h - b - 1))
        let taperB = min(max(taper * p, b + 1), max(1, w - s - r - 0.5))
        let taperS = min(max(taper * p, s + 1), max(1, h - b - r - 0.5))
        let pos = max(positive * p, 0.5)
        let neg = max(negative * p, 0.5)
        let cPosB = min(pos * 2, taperB * 0.42)
        let cNegB = min(neg * 2, taperB * 0.42)
        let cPosS = min(pos * 2, taperS * 0.42)
        let cNegS = min(neg * 2, taperS * 0.42)

        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addCurve(
            to: CGPoint(x: taperB, y: h - b),
            control1: CGPoint(x: cNegB, y: h),
            control2: CGPoint(x: taperB - cPosB, y: h - b)
        )
        path.addLine(to: CGPoint(x: w - s - r, y: h - b))
        if r > 0.5 {
            path.addArc(
                center: CGPoint(x: w - s - r, y: h - b - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )
        }
        path.addLine(to: CGPoint(x: w - s, y: taperS))
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - s, y: taperS - cPosS),
            control2: CGPoint(x: w, y: cNegS)
        )
        path.closeSubpath()
        return path
    }
}

struct SpaceHintView: View {
    @ObservedObject var state: PressState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.pressed ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(state.pressed ? "按下" : "按住空格，模拟实体键")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

final class SpaceCatcherView: NSView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            if !event.isARepeat { onDown?() }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            onUp?()
            return
        }
        super.keyUp(with: event)
    }
}

struct SpaceCatcher: NSViewRepresentable {
    var onDown: () -> Void
    var onUp: () -> Void

    func makeNSView(context: Context) -> SpaceCatcherView {
        let view = SpaceCatcherView()
        view.onDown = onDown
        view.onUp = onUp
        return view
    }

    func updateNSView(_ view: SpaceCatcherView, context: Context) {
        view.onDown = onDown
        view.onUp = onUp
    }
}
