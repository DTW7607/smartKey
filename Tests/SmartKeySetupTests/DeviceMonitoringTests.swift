import Testing
@testable import smartKeyPopup

@Suite @MainActor
struct DeviceMonitoringTests {
    @Test func unauthorizedSettingsKeepDeviceUpdatesOnlyWhileVisible() {
        var events: [String] = []
        let monitoring = DeviceMonitoringController(start: { events.append("start") }, stop: { events.append("stop") })
        monitoring.update(residentAuthorized: false, settingsVisible: false)
        #expect(events.isEmpty)
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        #expect(monitoring.isRunning)
        #expect(events == ["start"])
        // Closing or minimizing an unauthorized window stops its device session.
        monitoring.update(residentAuthorized: false, settingsVisible: false)
        #expect(!monitoring.isRunning)
        #expect(events == ["start", "stop"])
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        #expect(events == ["start", "stop", "start"])
    }

    @Test func grantAndRevocationPreserveVisibleDeviceSetupWithoutRestarting() {
        var events: [String] = []
        let monitoring = DeviceMonitoringController(start: { events.append("start") }, stop: { events.append("stop") })
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        monitoring.update(residentAuthorized: true, settingsVisible: true)
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        #expect(events == ["start"])
        monitoring.update(residentAuthorized: false, settingsVisible: false)
        #expect(events == ["start", "stop"])
    }

    @Test func authorizedMonitoringContinuesAfterSettingsClose() {
        var events: [String] = []
        let monitoring = DeviceMonitoringController(start: { events.append("start") }, stop: { events.append("stop") })
        monitoring.update(residentAuthorized: true, settingsVisible: false)
        monitoring.update(residentAuthorized: true, settingsVisible: true)
        monitoring.update(residentAuthorized: true, settingsVisible: false)
        #expect(events == ["start"])
        monitoring.update(residentAuthorized: false, settingsVisible: false)
        #expect(events == ["start", "stop"])
    }
}
