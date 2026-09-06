import AppKit
import SwiftUI
import Testing
@testable import SmartKey
@testable import smartKeyPopup

private let headphones = SmartKeyAudioDevice(uid: "jack", name: "外置耳机", transport: .builtIn, isAnalogJack: true)
private let speakers = SmartKeyAudioDevice(uid: "speakers", name: "MacBook Air 扬声器", transport: .builtIn, isAnalogJack: false)
private let bluetooth = SmartKeyAudioDevice(uid: "bluetooth", name: "DTW 的 AirPods Pro", transport: .bluetooth, isAnalogJack: false)

private final class MemoryChoiceStore: DeviceChoiceStoring {
    var lastChoice: DeviceTypeChoice
    init(_ choice: DeviceTypeChoice = .smartKey) { lastChoice = choice }
}

private final class FakeBackend: DeviceSetupBackend {
    var isJackConnected = true
    var devices = [headphones, speakers, bluetooth]
    var defaultUID = "jack"
    var seizeStatus: SmartKeySeizeStatus = .idle
    var seizeDiagnostic: String? = "模拟设备占用"
    var writes: [String] = []
    var remoteRequests: [Bool] = []
    var applyImmediately = true
    var throwOnWrite = false
    var seizeImmediately = true
    var audio: SmartKeyAudioSnapshot {
        SmartKeyAudioSnapshot(outputs: devices, inputs: [], defaultOutputUID: defaultUID, defaultInputUID: nil)
    }
    func setDefaultOutput(uid: String) throws {
        writes.append(uid)
        if throwOnWrite { throw SmartKeyAudioError.notSelectable(uid) }
        if applyImmediately { defaultUID = uid }
    }
    func setRemoteEnabled(_ enabled: Bool) {
        remoteRequests.append(enabled)
        seizeStatus = enabled ? (seizeImmediately ? .seized : .waiting) : .idle
    }
}

@Suite @MainActor
struct DeviceSetupTests {
    @Test func startupAndTimeoutOnlyChooseType() {
        let backend = FakeBackend()
        var clock: TimeInterval = 100
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(false)
        #expect(model.stage == .disconnected)
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        clock = 109.1
        model.tick()
        #expect(model.remainingSeconds == 1)
        // Duplicate HAL notifications cannot restart the deadline.
        model.jackChanged(true)
        clock = 110
        model.tick()
        #expect(model.stage == .choosingOutput)
        #expect(backend.writes.isEmpty)
        #expect(!backend.remoteRequests.contains(true))
    }

    @Test func choosingAudioLeavesOutputAndHIDAlone() {
        let backend = FakeBackend()
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        model.chooseAudioDevice()
        clock = 20
        model.tick()
        #expect(model.stage == .audioDevice)
        #expect(backend.defaultUID == "jack")
        #expect(backend.writes.isEmpty)
        #expect(!backend.remoteRequests.contains(true))
    }

    @Test func soleOutputSkipsPickerButWaitsForRouteConfirmation() {
        let backend = FakeBackend()
        backend.devices = [headphones, speakers]
        backend.applyImmediately = false
        let model = DeviceSetupModel(backend: backend)
        var stages: [DeviceSetupModel.Stage] = []
        model.onStageChange = { stages.append(model.stage) }
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        model.chooseSmartKey()
        #expect(model.stage == .applying)
        #expect(model.automaticallySelectingOutput)
        #expect(!stages.contains(.choosingOutput))
        #expect(backend.writes == ["speakers"])
        #expect(!backend.remoteRequests.contains(true))
        backend.defaultUID = "speakers"
        model.audioChanged(backend.audio)
        #expect(model.acceptsButtons)
    }

    @Test func timeoutUsesSoleCurrentOutputWithoutRewritingIt() {
        let backend = FakeBackend()
        backend.devices = [headphones, bluetooth]
        backend.defaultUID = "bluetooth"
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        clock = 10
        model.tick()
        #expect(model.stage == .active)
        #expect(backend.writes.isEmpty)
        #expect(model.automaticallySelectingOutput)
    }

    @Test func soleOutputFailureReturnsToPickerWithoutAutomaticRetry() {
        for throwsError in [false, true] {
            let backend = FakeBackend()
            backend.devices = [headphones, speakers]
            backend.applyImmediately = false
            backend.throwOnWrite = throwsError
            var clock: TimeInterval = 0
            let model = DeviceSetupModel(backend: backend, now: { clock })
            model.jackChanged(true)
            model.chooseSmartKey()
            clock = 4
            model.tick()
            #expect(model.stage == .choosingOutput)
            #expect(model.error != nil)
            #expect(!backend.remoteRequests.contains(true))
            model.audioChanged(backend.audio)
            model.tick()
            #expect(backend.writes.count == 1)
        }
    }

    @Test func noAlternativeOutputKeepsPickerOpen() {
        let backend = FakeBackend()
        backend.devices = [headphones]
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        #expect(model.stage == .choosingOutput)
        #expect(model.isPresented)
        #expect(!model.canApply)
        #expect(backend.writes.isEmpty)
        #expect(!backend.remoteRequests.contains(true))
    }

    @Test func outputMustBeConfirmedBeforeSeizing() {
        let backend = FakeBackend()
        backend.applyImmediately = false
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.selectedUID = "jack"
        #expect(!model.canApply)
        model.applyOutput()
        #expect(backend.writes.isEmpty)
        model.selectedUID = "bluetooth"
        model.applyOutput()
        #expect(model.stage == .applying)
        #expect(!backend.remoteRequests.contains(true))
        backend.defaultUID = "bluetooth"
        model.audioChanged(backend.audio)
        #expect(model.stage == .active)
        #expect(model.acceptsButtons)
        #expect(backend.writes == ["bluetooth"])
    }

    @Test func unplugCancelsPendingSetupAndRequiresNewChoice() {
        let backend = FakeBackend()
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        backend.isJackConnected = false
        model.jackChanged(false)
        clock = 11
        model.tick()
        #expect(model.stage == .disconnected)
        backend.isJackConnected = true
        model.jackChanged(true)
        model.chooseSmartKey()
        backend.applyImmediately = false
        model.applyOutput()
        backend.isJackConnected = false
        model.jackChanged(false)
        backend.defaultUID = "speakers"
        model.audioChanged(backend.audio)
        #expect(model.stage == .disconnected)
        #expect(!backend.remoteRequests.contains(true))
        backend.isJackConnected = true
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        #expect(model.remainingSeconds == 10)
    }

    @Test func writeFailureAndTimeoutNeverEnableHID() {
        for throwsError in [false, true] {
            let backend = FakeBackend()
            backend.throwOnWrite = throwsError
            backend.applyImmediately = false
            var clock: TimeInterval = 0
            let model = DeviceSetupModel(backend: backend, now: { clock })
            model.jackChanged(true)
            model.chooseSmartKey()
            model.applyOutput()
            clock = 4
            model.tick()
            #expect(model.stage == .choosingOutput)
            #expect(model.error != nil)
            #expect(!backend.remoteRequests.contains(true))
        }
    }

    @Test func outputDisappearsAndSeizeFails() {
        let backend = FakeBackend()
        backend.seizeImmediately = false
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        model.chooseSmartKey()
        backend.devices = [headphones]
        model.audioChanged(backend.audio)
        #expect(model.selectedUID == nil)
        #expect(!model.canApply)
        backend.devices = [headphones, speakers]
        model.audioChanged(backend.audio)
        model.applyOutput()
        #expect(model.stage == .activating)
        #expect(!model.acceptsButtons)
        clock = 6
        model.tick()
        #expect(model.stage == .activating)
        #expect(model.error != nil)
        #expect(backend.remoteRequests.last == true)
        backend.seizeStatus = .seized
        model.tick()
        #expect(model.stage == .active)
        #expect(model.error == nil)
        backend.seizeStatus = .failed
        model.seizeChanged(.failed)
        #expect(model.stage == .remoteError)
        #expect(model.error == "模拟设备占用")
        #expect(!model.acceptsButtons)
        backend.seizeImmediately = true
        model.retryRemote()
        #expect(model.stage == .active)
    }

    @Test func activeOutputLossReleasesHIDAndCancelStopsRetry() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        #expect(model.acceptsButtons)
        backend.defaultUID = "jack"
        model.audioChanged(backend.audio)
        #expect(model.stage == .choosingOutput)
        #expect(backend.remoteRequests.last == false)
        let writes = backend.writes
        model.cancel()
        model.tick()
        #expect(model.stage == .paused)
        #expect(backend.writes == writes)
        model.reopen()
        #expect(model.stage == .choosingType)
        #expect(!model.hasAutomaticChoice)
    }

    @Test func audioChoiceSwitchesToJackAndConfirmsReadback() {
        let backend = FakeBackend()
        backend.defaultUID = "bluetooth"
        backend.applyImmediately = false
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        model.chooseAudioDevice()
        #expect(backend.writes == ["jack"])
        #expect(model.stage == .applyingAudio)
        clock = 4
        model.tick()
        #expect(model.stage == .audioError)
        backend.applyImmediately = true
        model.chooseAudioDevice()
        #expect(model.stage == .audioDevice)
        #expect(backend.defaultUID == "jack")
        #expect(!backend.remoteRequests.contains(true))
    }

    @Test func everyInsertionPromptsEvenWithKnownOutput() {
        let backend = FakeBackend()
        backend.defaultUID = "bluetooth"
        let model = DeviceSetupModel(backend: backend)
        model.audioChanged(backend.audio)
        model.jackChanged(true)
        #expect(model.isPresented)
        #expect(model.stage == .choosingType)
        model.chooseSmartKey()
        #expect(model.stage == .choosingOutput)
        #expect(model.selectedUID == "bluetooth")
        #expect(!model.outputs.contains { $0.isAnalogJack })
        #expect(backend.writes.isEmpty)
        #expect(!backend.remoteRequests.contains(true))
        model.applyOutput()
        #expect(model.stage == .active)
        #expect(backend.writes.isEmpty)
        backend.isJackConnected = false
        model.jackChanged(false)
        backend.isJackConnected = true
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        #expect(model.isPresented)
    }

    @Test func insertionPopupDelayHidesUntilDeadline() {
        let backend = FakeBackend()
        var clock: TimeInterval = 0
        let timing = DeviceSetupTiming(choiceTimeout: 2.5, popupDelay: 0.2)
        let model = DeviceSetupModel(backend: backend, timing: timing, now: { clock })
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        #expect(!model.isPresented)
        #expect(model.isWaitingToPresent)
        clock = 0.19
        model.tick()
        #expect(!model.isPresented)
        clock = 0.2
        model.tick()
        #expect(model.isPresented)
        #expect(!model.isWaitingToPresent)
        #expect(model.hasAutomaticChoice)
        #expect(model.remainingSeconds == 3)
        clock = 2.7
        model.tick()
        #expect(model.stage == .choosingOutput)
    }

    @Test func unplugDuringPopupDelayCancelsPresentation() {
        let backend = FakeBackend()
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, timing: DeviceSetupTiming(popupDelay: 0.2), now: { clock })
        model.jackChanged(true)
        backend.isJackConnected = false
        model.jackChanged(false)
        clock = 1
        model.tick()
        #expect(model.stage == .disconnected)
        #expect(!model.isPresented)
        #expect(!model.isWaitingToPresent)
    }

    @Test func timeoutSelectsRememberedAudioDevice() {
        let backend = FakeBackend()
        let store = MemoryChoiceStore(.audioDevice)
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, choiceStore: store, now: { clock })
        #expect(model.preferredChoice == .audioDevice)
        model.jackChanged(true)
        clock = 10
        model.tick()
        #expect(model.stage == .audioDevice)
        #expect(store.lastChoice == .audioDevice)
        #expect(!backend.remoteRequests.contains(true))
    }

    @Test func nextInsertionRestoresLastChoiceFocus() {
        let backend = FakeBackend()
        let store = MemoryChoiceStore()
        let model = DeviceSetupModel(backend: backend, choiceStore: store)
        model.jackChanged(true)
        #expect(model.preferredChoice == .smartKey)
        model.chooseAudioDevice()
        #expect(store.lastChoice == .audioDevice)
        backend.isJackConnected = false
        model.jackChanged(false)
        backend.isJackConnected = true
        model.jackChanged(true)
        #expect(model.stage == .choosingType)
        #expect(model.preferredChoice == .audioDevice)
    }

    @Test func reopenRestoresLastChoiceWithoutCountdown() {
        let backend = FakeBackend()
        let store = MemoryChoiceStore(.audioDevice)
        let model = DeviceSetupModel(backend: backend, choiceStore: store)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        model.reopen()
        #expect(model.stage == .choosingType)
        #expect(model.preferredChoice == .smartKey)
        #expect(!model.hasAutomaticChoice)
        #expect(model.isPresented)
    }

    @Test func runtimeSettingsParseSetupKeys() {
        let settings = RuntimeSettings.parse("""
            deviceChoiceTimeoutMs = 2500
            insertionPopupDelayMs = 150
            insertionMaskDurationMs = 900
            insertionMaskAppearMs = 80
            insertionMaskDisappearMs = 160
            setupChoiceWidthPt = 400
            unknownKey = 1
            deviceChoiceTimeoutMs = no
            setupChoiceWidthPt = 200
            """)
        #expect(settings.deviceChoiceTimeoutMs == 2500)
        #expect(settings.insertionPopupDelayMs == 150)
        #expect(settings.setupChoiceWidthPt == 400)
        #expect(settings.doubleClickMs == 450)
        #expect(settings.setupTiming.choiceTimeout == 2.5)
        #expect(settings.setupTiming.popupDelay == 0.15)
        #expect(settings.insertionAnimation.duration == 0.9)
        #expect(settings.insertionAnimation.appear == 0.08)
        #expect(settings.insertionAnimation.disappear == 0.16)
        #expect(settings.insertionAnimation.releaseAfter == 0.74)
    }

    @Test func runtimeSettingsSerializeRoundTrips() {
        let original = RuntimeSettings.parse("""
            sidePt = 7
            bubbleHoldMs = 2000
            shadowOpacity = 0.25
            """)
        let again = RuntimeSettings.parse(original.serialized())
        #expect(again == original)
        #expect(RuntimeSettings.parse(RuntimeSettings().serialized()) == RuntimeSettings())
    }

    @Test func missingConfIsCreatedFromFactoryThenLoaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let factoryDir = dir.appendingPathComponent("factory", isDirectory: true)
        let userDir = dir.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: factoryDir, withIntermediateDirectories: true)
        let factory = factoryDir.appendingPathComponent("smartKey.conf")
        try "sidePt = 9\n".write(to: factory, atomically: true, encoding: .utf8)
        let user = userDir.appendingPathComponent("smartKey.conf")
        let url = RuntimeConfiguration.ensureFile(at: user, factory: factory)
        let config = RuntimeConfiguration.load(url: url)
        #expect(config.sidePt == 9)

        let missingFactory = dir.appendingPathComponent("nope.conf")
        let user2 = dir.appendingPathComponent("user2/smartKey.conf")
        let url2 = RuntimeConfiguration.ensureFile(at: user2, factory: missingFactory)
        let text = try String(contentsOf: url2, encoding: .utf8)
        #expect(RuntimeSettings.parse(text) == RuntimeSettings())
    }

    @Test func deviceChoiceStoreRoundTrips() {
        let suite = "smartKey.tests.deviceChoice"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DeviceChoiceStore(defaults: defaults)
        #expect(store.lastChoice == .smartKey)
        store.lastChoice = .audioDevice
        #expect(DeviceChoiceStore(defaults: defaults).lastChoice == .audioDevice)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func displayPrefersActiveBuiltInThenSystemMain() {
        let builtIn = DisplayPlacement.Display(id: 1, builtIn: true, active: true)
        let external = DisplayPlacement.Display(id: 2, builtIn: false, active: true)
        #expect(DisplayPlacement.preferredID([external, builtIn], mainID: 2) == 1)
        #expect(DisplayPlacement.preferredID([.init(id: 1, builtIn: true, active: false), external], mainID: 2) == 2)
        #expect(DisplayPlacement.preferredID([external], mainID: 2) == 2)
        #expect(DisplayPlacement.preferredID([], mainID: 2) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMARTKEY_HID_INTEGRATION"] == "1"))
    func realHIDCanRestartThreeTimes() {
        let watcher = HIDWatcher()
        defer { watcher.stop() }
        for _ in 1...3 {
            watcher.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            #expect(watcher.seizeStatus == .seized)
            watcher.stop()
            #expect(watcher.seizeStatus == .idle)
        }
    }

    @Test func renderSetupWindows() throws {
        guard #available(macOS 26.0, *) else { return }
        _ = NSApplication.shared
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        for name in ["device-type", "audio-output", "audio-output-dark", "audio-error"] {
            if name == "audio-output" { model.chooseSmartKey() }
            if name == "audio-error" { backend.throwOnWrite = true; model.applyOutput() }
            let view = NSHostingView(rootView: DeviceSetupView(model: model))
            let window = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name.hasSuffix("-dark") ? .darkAqua : .aqua)
            window.contentView = view
            window.setContentSize(view.fittingSize)
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            func inspect(_ node: NSView) {
                if let table = node as? NSTableView {
                    #expect(table.numberOfRows == backend.devices.filter { !$0.isAnalogJack }.count)
                    #expect(table.selectedRow == 0)
                    #expect(table.delegate?.tableView?(table, shouldSelectRow: 0) == true)
                    #expect(table.frame.width > 400)
                }
                node.subviews.forEach(inspect)
            }
            inspect(view)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/smartKey-\(name).png"))
            #expect(view.fittingSize.width >= 400)
        }
    }
}
