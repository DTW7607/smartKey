import Foundation

final class GestureRecognizerScheduledTask {
    private let cancelAction: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancelAction = cancel
    }

    func cancel() {
        cancelAction()
    }
}

protocol GestureRecognizerScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> GestureRecognizerScheduledTask
}

private final class MainGestureRecognizerScheduler: GestureRecognizerScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> GestureRecognizerScheduledTask {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return GestureRecognizerScheduledTask(cancel: work.cancel)
    }
}

final class GestureRecognizer {
    var configuration: SmartKeyConfiguration
    var onButton: ((SmartKeyButtonPhase) -> Void)?
    var onGesture: ((SmartKeyGestureEvent) -> Void)?
    var onSessionStart: (() -> Void)?
    var onSessionEnd: (() -> Void)?

    private(set) var isButtonPressed = false

    private enum State {
        case idle
        case down(longArmed: Bool)
        case waitingForDouble
        case downSecond
        case downLongFired
    }

    private var state: State = .idle
    private var longPressWork: GestureRecognizerScheduledTask?
    private var singleClickWork: GestureRecognizerScheduledTask?
    private var sessionConfiguration: SmartKeyConfiguration?
    private var sessionID: UInt64?
    private var nextSessionID: UInt64 = 0
    private var singleCount = 0
    private var doubleCount = 0
    private var longCount = 0
    private let scheduler: GestureRecognizerScheduler

    private var activeConfiguration: SmartKeyConfiguration {
        sessionConfiguration ?? configuration
    }

    private var enabled: SmartKeyEventKind { activeConfiguration.enabledEvents }

    init(
        configuration: SmartKeyConfiguration,
        scheduler: GestureRecognizerScheduler = MainGestureRecognizerScheduler()
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
    }

    func handle(pressed: Bool) {
        if pressed { handleDown() } else { handleUp() }
    }

    func applyConfiguration(_ new: SmartKeyConfiguration) {
        configuration = new
    }

    func reset() {
        cancel(&longPressWork)
        cancel(&singleClickWork)
        if isButtonPressed {
            isButtonPressed = false
            emitButton(.released)
        }
        endSession()
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
            startSession()
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
                endSession()
            }
        case .downSecond, .downLongFired:
            isButtonPressed = false
            emitButton(.released)
            endSession()
        case .idle, .waitingForDouble:
            break
        }
    }

    private func armLongPress() {
        cancel(&longPressWork)
        guard let sessionID else { return }
        let delay = activeConfiguration.longPressDuration
        let work = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.sessionID == sessionID else { return }
            self.fireLongPress()
        }
        longPressWork = work
    }

    private func armSingleClick() {
        cancel(&singleClickWork)
        guard let sessionID else { return }
        let delay = activeConfiguration.doubleClickGap
        let work = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.sessionID == sessionID else { return }
            self.fireSingle()
        }
        singleClickWork = work
    }

    private func fireLongPress() {
        guard case .down(let longArmed) = state, longArmed, isButtonPressed else { return }
        longPressWork = nil
        emitGesture(.longPress)
        state = .downLongFired
    }

    private func fireSingle() {
        guard case .waitingForDouble = state else { return }
        singleClickWork = nil
        emitGesture(.singleClick)
        endSession()
    }

    private func startSession() {
        precondition(sessionID == nil)
        nextSessionID &+= 1
        sessionID = nextSessionID
        sessionConfiguration = configuration
        onSessionStart?()
    }

    private func endSession() {
        guard sessionID != nil else {
            state = .idle
            return
        }
        state = .idle
        sessionID = nil
        sessionConfiguration = nil
        onSessionEnd?()
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

    private func cancel(_ work: inout GestureRecognizerScheduledTask?) {
        work?.cancel()
        work = nil
    }
}
