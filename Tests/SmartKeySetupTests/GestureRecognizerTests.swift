import Foundation
import Testing
@testable import SmartKey

private final class TestGestureScheduler: GestureRecognizerScheduler {
    private struct Entry {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
    }

    private var nextID = 0
    private var entries: [Int: Entry] = [:]

    var pendingDelays: [TimeInterval] {
        entries.values
            .filter { !$0.cancelled }
            .map(\.delay)
            .sorted()
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> GestureRecognizerScheduledTask {
        nextID += 1
        let id = nextID
        entries[id] = Entry(delay: delay, action: action)
        return GestureRecognizerScheduledTask { [weak self] in
            self?.entries[id]?.cancelled = true
        }
    }

    func fireNext() {
        guard let id = entries
            .filter({ !$0.value.cancelled })
            .min(by: { lhs, rhs in
                if lhs.value.delay == rhs.value.delay { return lhs.key < rhs.key }
                return lhs.value.delay < rhs.value.delay
            })?.key,
            let entry = entries.removeValue(forKey: id)
        else { return }
        entry.action()
    }

    func fireAll() {
        while !pendingDelays.isEmpty {
            fireNext()
        }
    }
}

private let allGestureEvents: SmartKeyEventKind = [.press, .release, .singleClick, .doubleClick, .longPress]

@Suite
struct GestureRecognizerTests {
    @Test func configurationChangeDuringDownKeepsCurrentSessionSnapshot() {
        let initial = SmartKeyConfiguration(
            doubleClickMs: 240,
            longPressMs: 80,
            enabledEvents: allGestureEvents
        )
        let scheduler = TestGestureScheduler()
        let recognizer = GestureRecognizer(configuration: initial, scheduler: scheduler)
        var buttons: [SmartKeyButtonPhase] = []
        var gestures: [SmartKeyGesture] = []
        recognizer.onButton = { buttons.append($0) }
        recognizer.onGesture = { gestures.append($0.gesture) }

        recognizer.handle(pressed: true)
        #expect(scheduler.pendingDelays == [0.08])

        recognizer.applyConfiguration(SmartKeyConfiguration(
            doubleClickMs: 900,
            longPressMs: 900,
            enabledEvents: [.press]
        ))

        // The old long-press setting and event enablement still belong to this down.
        scheduler.fireNext()
        #expect(gestures == [.longPress])
        recognizer.handle(pressed: false)
        #expect(buttons == [.pressed, .released])

        // A fresh down sees the latest configuration.
        recognizer.handle(pressed: true)
        #expect(scheduler.pendingDelays.isEmpty)
        recognizer.handle(pressed: false)
        #expect(buttons == [.pressed, .released, .pressed])
        #expect(gestures == [.longPress])
    }

    @Test func configurationChangeWhileWaitingDoesNotCompleteOrRewriteCurrentSession() {
        let initial = SmartKeyConfiguration(
            doubleClickMs: 240,
            longPressMs: 900,
            enabledEvents: allGestureEvents
        )
        let scheduler = TestGestureScheduler()
        let recognizer = GestureRecognizer(configuration: initial, scheduler: scheduler)
        var gestures: [SmartKeyGesture] = []
        var sessions: [String] = []
        recognizer.onGesture = { gestures.append($0.gesture) }
        recognizer.onSessionStart = { sessions.append("start") }
        recognizer.onSessionEnd = { sessions.append("end") }

        recognizer.handle(pressed: true)
        recognizer.handle(pressed: false)
        #expect(scheduler.pendingDelays == [0.24])
        #expect(sessions == ["start"])

        recognizer.applyConfiguration(SmartKeyConfiguration(
            doubleClickMs: 900,
            longPressMs: 900,
            enabledEvents: [.press]
        ))

        // Disabling double-click must not synthesize a click or end this session.
        #expect(gestures.isEmpty)
        #expect(scheduler.pendingDelays == [0.24])
        #expect(sessions == ["start"])

        // The pending decision still uses the old session's rules.
        scheduler.fireNext()
        #expect(gestures == [.singleClick])
        #expect(sessions == ["start", "end"])
    }

    @Test func resetCancelsPendingWorkAndNextSessionUsesLatestConfiguration() {
        let scheduler = TestGestureScheduler()
        let recognizer = GestureRecognizer(
            configuration: SmartKeyConfiguration(
                doubleClickMs: 240,
                longPressMs: 900,
                enabledEvents: allGestureEvents
            ),
            scheduler: scheduler
        )
        var buttons: [SmartKeyButtonPhase] = []
        var gestures: [SmartKeyGesture] = []
        var sessionStarts = 0
        var sessionEnds = 0
        recognizer.onButton = { buttons.append($0) }
        recognizer.onGesture = { gestures.append($0.gesture) }
        recognizer.onSessionStart = { sessionStarts += 1 }
        recognizer.onSessionEnd = { sessionEnds += 1 }

        recognizer.handle(pressed: true)
        recognizer.handle(pressed: false)
        recognizer.applyConfiguration(SmartKeyConfiguration(
            doubleClickMs: 900,
            longPressMs: 900,
            enabledEvents: [.press]
        ))
        #expect(scheduler.pendingDelays == [0.24])

        recognizer.reset()
        #expect(scheduler.pendingDelays.isEmpty)
        #expect(gestures.isEmpty)
        #expect(sessionStarts == 1)
        #expect(sessionEnds == 1)

        recognizer.handle(pressed: true)
        recognizer.handle(pressed: false)
        scheduler.fireAll()
        #expect(buttons == [.pressed, .released, .pressed])
        #expect(gestures.isEmpty)
        #expect(sessionStarts == 2)
        #expect(sessionEnds == 2)
    }

    @Test func defaultDoubleClickStillWinsBeforePendingSingle() {
        let scheduler = TestGestureScheduler()
        let recognizer = GestureRecognizer(
            configuration: SmartKeyConfiguration(
                doubleClickMs: 240,
                longPressMs: 900,
                enabledEvents: allGestureEvents
            ),
            scheduler: scheduler
        )
        var buttons: [SmartKeyButtonPhase] = []
        var gestures: [SmartKeyGesture] = []
        var sessionStarts = 0
        var sessionEnds = 0
        recognizer.onButton = { buttons.append($0) }
        recognizer.onGesture = { gestures.append($0.gesture) }
        recognizer.onSessionStart = { sessionStarts += 1 }
        recognizer.onSessionEnd = { sessionEnds += 1 }

        recognizer.handle(pressed: true)
        recognizer.handle(pressed: false)
        recognizer.handle(pressed: true)
        #expect(gestures == [.doubleClick])
        #expect(buttons == [.pressed, .released, .pressed])
        #expect(sessionStarts == 1)
        #expect(sessionEnds == 0)

        recognizer.handle(pressed: false)
        scheduler.fireAll()
        #expect(gestures == [.doubleClick])
        #expect(buttons == [.pressed, .released, .pressed, .released])
        #expect(sessionStarts == 1)
        #expect(sessionEnds == 1)
    }
}
