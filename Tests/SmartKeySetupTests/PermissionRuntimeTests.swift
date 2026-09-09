import Testing
@testable import smartKeyPopup

@Suite @MainActor
struct PermissionRuntimeTests {
    @Test func unauthorizedLaunchDoesNotStartRuntimeAndClosingLastWindowExits() {
        var events: [String] = []
        let runtime = PermissionRuntimeController(start: { events.append("start") }, stop: { events.append("stop") },
            showRestrictedWindow: { events.append("show") }, terminate: { events.append("exit") })
        runtime.update(authorized: false, hasVisibleWindow: true)
        #expect(events.isEmpty)
        #expect(!runtime.isRunning)
        runtime.windowClosed(authorized: false, hasVisibleWindow: false)
        #expect(events == ["exit"])
        runtime.windowClosed(authorized: false, hasVisibleWindow: false)
        runtime.update(authorized: true, hasVisibleWindow: false)
        #expect(events == ["exit"])
    }

    @Test func guideToSettingsTransitionDoesNotStartRuntimeOrExit() {
        var events: [String] = []
        let runtime = PermissionRuntimeController(start: { events.append("start") }, stop: { events.append("stop") },
            showRestrictedWindow: { events.append("show") }, terminate: { events.append("exit") })
        runtime.windowClosed(authorized: false, hasVisibleWindow: true)
        #expect(events.isEmpty)
        runtime.windowClosed(authorized: false, hasVisibleWindow: false)
        #expect(events == ["exit"])
    }

    @Test func grantStartsOnceAndAuthorizedWindowClosureKeepsRuntime() {
        var events: [String] = []
        let runtime = PermissionRuntimeController(start: { events.append("start") }, stop: { events.append("stop") },
            showRestrictedWindow: { events.append("show") }, terminate: { events.append("exit") })
        runtime.update(authorized: true, hasVisibleWindow: true)
        runtime.update(authorized: true, hasVisibleWindow: true)
        runtime.windowClosed(authorized: true, hasVisibleWindow: false)
        #expect(events == ["start"])
        #expect(runtime.isRunning)
        runtime.shutdown()
        #expect(events == ["start", "stop"])
    }

    @Test func revocationStopsRuntimeAndShowsWindowOnlyWhenNeeded() {
        for hasWindow in [false, true] {
            var events: [String] = []
            let runtime = PermissionRuntimeController(start: { events.append("start") }, stop: { events.append("stop") },
                showRestrictedWindow: { events.append("show") }, terminate: { events.append("exit") })
            runtime.update(authorized: true, hasVisibleWindow: hasWindow)
            runtime.update(authorized: false, hasVisibleWindow: hasWindow)
            runtime.update(authorized: false, hasVisibleWindow: true)
            #expect(events == (hasWindow ? ["start", "stop"] : ["start", "stop", "show"]))
            #expect(!runtime.isRunning)
            runtime.update(authorized: true, hasVisibleWindow: true)
            #expect(events.last == "start")
            runtime.windowClosed(authorized: false, hasVisibleWindow: false)
            #expect(Array(events.suffix(2)) == ["stop", "exit"])
        }
    }

    @Test func permissionGrantedJustBeforeClosingStartsRuntimeInsteadOfExiting() {
        var events: [String] = []
        let runtime = PermissionRuntimeController(start: { events.append("start") }, stop: { events.append("stop") },
            showRestrictedWindow: { events.append("show") }, terminate: { events.append("exit") })
        runtime.windowClosed(authorized: true, hasVisibleWindow: false)
        #expect(events == ["start"])
    }
}
