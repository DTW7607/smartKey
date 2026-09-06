import Foundation

final class GestureRecognizer {
    var configuration: SmartKeyConfiguration
    var onButton: ((SmartKeyButtonPhase) -> Void)?
    var onGesture: ((SmartKeyGestureEvent) -> Void)?

    private(set) var isButtonPressed = false

    private enum State {
        case idle
        case down(longArmed: Bool)
        case waitingForDouble
        case downSecond
        case downLongFired
    }

    private var state: State = .idle
    private var longPressWork: DispatchWorkItem?
    private var singleClickWork: DispatchWorkItem?
    private var singleCount = 0
    private var doubleCount = 0
    private var longCount = 0

    private var enabled: SmartKeyEventKind { configuration.enabledEvents }

    init(configuration: SmartKeyConfiguration) {
        self.configuration = configuration
    }

    func handle(pressed: Bool) {
        if pressed { handleDown() } else { handleUp() }
    }

    func applyConfiguration(_ new: SmartKeyConfiguration) {
        configuration = new
        if !new.enabledEvents.contains(.longPress), case .down(true) = state {
            cancel(&longPressWork)
            state = .down(longArmed: false)
        }
        if !new.enabledEvents.contains(.doubleClick), case .waitingForDouble = state {
            cancel(&singleClickWork)
            emitGesture(.singleClick)
            state = .idle
        }
    }

    func reset() {
        cancel(&longPressWork)
        cancel(&singleClickWork)
        if isButtonPressed {
            isButtonPressed = false
            emitButton(.released)
        }
        state = .idle
    }

    func resetCounts() {
        singleCount = 0
        doubleCount = 0
        longCount = 0
    }

    private func handleDown() {
        switch state {
        case .waitingForDouble:
            isButtonPressed = true
            emitButton(.pressed)
            cancel(&singleClickWork)
            cancel(&longPressWork)
            emitGesture(.doubleClick)
            state = .downSecond
        case .idle:
            isButtonPressed = true
            emitButton(.pressed)
            let longOn = enabled.contains(.longPress)
            state = .down(longArmed: longOn)
            if longOn { armLongPress() }
        case .down, .downSecond, .downLongFired:
            break
        }
    }

    private func handleUp() {
        switch state {
        case .down:
            isButtonPressed = false
            emitButton(.released)
            cancel(&longPressWork)
            if enabled.contains(.doubleClick) {
                state = .waitingForDouble
                armSingleClick()
            } else {
                emitGesture(.singleClick)
                state = .idle
            }
        case .downSecond, .downLongFired:
            isButtonPressed = false
            emitButton(.released)
            state = .idle
        case .idle, .waitingForDouble:
            break
        }
    }

    private func armLongPress() {
        cancel(&longPressWork)
        let work = DispatchWorkItem { [weak self] in
            self?.fireLongPress()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.longPressDuration, execute: work)
    }

    private func armSingleClick() {
        cancel(&singleClickWork)
        let work = DispatchWorkItem { [weak self] in
            self?.fireSingle()
        }
        singleClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.doubleClickGap, execute: work)
    }

    private func fireLongPress() {
        guard case .down(let longArmed) = state, longArmed, isButtonPressed else { return }
        emitGesture(.longPress)
        state = .downLongFired
    }

    private func fireSingle() {
        guard case .waitingForDouble = state else { return }
        emitGesture(.singleClick)
        state = .idle
    }

    private func emitButton(_ phase: SmartKeyButtonPhase) {
        let kind: SmartKeyEventKind = phase == .pressed ? .press : .release
        guard enabled.contains(kind) else { return }
        onButton?(phase)
    }

    private func emitGesture(_ gesture: SmartKeyGesture) {
        let kind: SmartKeyEventKind
        switch gesture {
        case .singleClick: kind = .singleClick
        case .doubleClick: kind = .doubleClick
        case .longPress: kind = .longPress
        }
        guard enabled.contains(kind) else { return }
        let count: Int
        switch gesture {
        case .singleClick:
            singleCount += 1
            count = singleCount
        case .doubleClick:
            doubleCount += 1
            count = doubleCount
        case .longPress:
            longCount += 1
            count = longCount
        }
        onGesture?(SmartKeyGestureEvent(gesture: gesture, count: count))
    }

    private func cancel(_ work: inout DispatchWorkItem?) {
        work?.cancel()
        work = nil
    }
}
