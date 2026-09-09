import AppKit
import SwiftUI
import Testing
import SmartKeyActions
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
    var guardRequests: [Bool] = []
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
    func setOutputGuardEnabled(_ enabled: Bool) {
        guardRequests.append(enabled)
    }
}

@Suite @MainActor
struct DeviceSetupTests {
    @Test func unauthorizedGeneralSettingsReceiveDevicesAndCanChangeAudioMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-unprivileged-general-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let permissions = PermissionsModel(check: { _ in false })
        let coordinator = try ActionCoordinator(configuration: RuntimeConfiguration(), directory: directory, permissions: permissions)
        let backend = FakeBackend()
        backend.isJackConnected = false
        let model = DeviceSetupModel(backend: backend, timing: DeviceSetupTiming(choiceTimeout: 0, popupDelay: 0))
        model.presentationHostForNewFlow = { .settings }
        coordinator.deviceSetup = model
        model.onStageChange = { coordinator.deviceConnected = model.stage != .disconnected }
        coordinator.onChooseAudioDevice = { model.chooseAudioDevice() }
        coordinator.onChooseSmartKey = { model.chooseSmartKey() }
        let monitoring = DeviceMonitoringController(start: {
            model.audioChanged(backend.audio)
            model.jackChanged(backend.isJackConnected)
        }, stop: { model.jackChanged(false) })
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        #expect(!coordinator.canUseActions)
        #expect(model.outputs == [speakers, bluetooth])
        #expect(!coordinator.deviceConnected)

        backend.isJackConnected = true
        model.jackChanged(true)
        #expect(coordinator.deviceConnected)
        #expect(model.presentationHost == .settings)
        coordinator.onChooseSmartKey?()
        #expect(model.canEditSettingsOutput)
        model.selectedUID = bluetooth.uid
        model.applySettingsOutput()
        #expect(model.stage == .active)
        #expect(backend.defaultUID == bluetooth.uid)
        #expect(!coordinator.canUseActions)
        coordinator.onChooseAudioDevice?()
        #expect(model.stage == .audioDevice)
        #expect(backend.defaultUID == headphones.uid)

        backend.devices = [headphones, speakers]
        model.audioChanged(backend.audio)
        #expect(model.outputs == [speakers])
        monitoring.update(residentAuthorized: false, settingsVisible: false)
        #expect(!coordinator.deviceConnected)
        #expect(backend.remoteRequests.last == false)
        #expect(backend.guardRequests.last == false)
        monitoring.update(residentAuthorized: false, settingsVisible: true)
        #expect(coordinator.deviceConnected)
        #expect(model.outputs == [speakers])
        coordinator.setPaused(true)
        #expect(coordinator.store.document.paused)
        coordinator.setPaused(false)
        #expect(!coordinator.store.document.paused)
    }
    @Test func popupFlowKeepsItsHostWhenSettingsOpens() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        var host = DeviceSetupModel.PresentationHost.popup
        model.presentationHostForNewFlow = { host }
        model.jackChanged(true)
        host = .settings
        model.chooseSmartKey()
        #expect(model.presentationHost == .popup)
        #expect(model.hasAutomaticOutputChoice)
        model.settingsDidHide()
        #expect(backend.writes.isEmpty)
        #expect(model.stage == .choosingOutput)
        model.applyOutput()
        #expect(model.presentationHost == nil)
        model.chooseSmartKey()
        #expect(model.presentationHost == .settings)
    }

    @Test func hidingSettingsExpiresChoicesWithoutMovingTheFlowOrRetryingErrors() {
        let backend = FakeBackend()
        backend.applyImmediately = false
        var clock: TimeInterval = 0
        var host = DeviceSetupModel.PresentationHost.settings
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.presentationHostForNewFlow = { host }
        model.jackChanged(true)
        host = .popup
        model.settingsDidHide()
        #expect(model.stage == .applying)
        #expect(model.presentationHost == .settings)
        #expect(backend.writes == [speakers.uid])
        clock = 100
        model.tick()
        #expect(model.stage == .choosingOutput)
        #expect(model.error != nil)
        model.tick()
        model.settingsDidShow()
        model.tick()
        #expect(backend.writes == [speakers.uid])
        #expect(model.presentationHost == .settings)
        model.cancel()
        model.jackChanged(false)
        model.jackChanged(true)
        #expect(model.presentationHost == .popup)
    }

    @Test(arguments: [DeviceSetupModel.PresentationHost.popup, .settings])
    func outputGetsFullChoiceTimeoutAndUsesFirstNotPreselection(host: DeviceSetupModel.PresentationHost) {
        let backend = FakeBackend()
        backend.defaultUID = bluetooth.uid
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, timing: DeviceSetupTiming(choiceTimeout: 5), now: { clock })
        model.presentationHostForNewFlow = { host }
        model.jackChanged(true)
        clock = 5
        model.tick()
        #expect(model.stage == .choosingOutput)
        #expect(model.selectedUID == bluetooth.uid)
        #expect(model.remainingSeconds == 5)
        clock = 9.2
        model.tick()
        #expect(model.remainingSeconds == 1)
        #expect(backend.writes.isEmpty)
        clock = 10
        model.tick()
        #expect(backend.writes == [speakers.uid])
        #expect(model.stage == .active)
    }

    @Test func hidingSettingsUsesPreferredTypeEvenWithTimerDisabled() {
        let backend = FakeBackend()
        backend.defaultUID = speakers.uid
        let model = DeviceSetupModel(backend: backend, timing: DeviceSetupTiming(choiceTimeout: 0, popupDelay: 1),
                                     choiceStore: MemoryChoiceStore(.audioDevice))
        model.presentationHostForNewFlow = { .settings }
        model.jackChanged(true)
        model.settingsDidHide()
        #expect(!model.isWaitingToPresent)
        #expect(backend.writes == [headphones.uid])
        #expect(model.stage == .audioDevice)
    }

    @Test func hidingSettingsExpiresOutputChoiceAndWaitsSafelyForEmptyList() {
        for empty in [false, true] {
            let backend = FakeBackend()
            if empty { backend.devices = [headphones] }
            let model = DeviceSetupModel(backend: backend)
            model.presentationHostForNewFlow = { .settings }
            model.jackChanged(true)
            model.chooseSmartKey()
            model.selectedUID = bluetooth.uid
            model.settingsDidHide()
            if empty {
                #expect(model.stage == .choosingOutput)
                #expect(backend.writes.isEmpty)
                backend.devices = [headphones, speakers, bluetooth]
                model.audioChanged(backend.audio)
                model.tick()
            }
            #expect(backend.writes == [speakers.uid])
            #expect(model.stage == .active)
        }
    }

    @Test func outputTimeoutUsesFreshListAndEmptyListWaits() {
        let backend = FakeBackend()
        var clock: TimeInterval = 0
        let model = DeviceSetupModel(backend: backend, now: { clock })
        model.jackChanged(true)
        model.chooseSmartKey()
        backend.devices = [headphones]
        clock = 10
        model.tick()
        #expect(!model.hasAutomaticOutputChoice)
        #expect(backend.writes.isEmpty)
        backend.devices = [headphones, bluetooth, speakers]
        clock = 20
        model.audioChanged(backend.audio)
        model.tick()
        #expect(model.remainingSeconds == 10)
        backend.devices = [headphones, speakers]
        clock = 30
        model.tick()
        #expect(backend.writes == [speakers.uid])
    }

    @Test func outputTimeoutStopsOnCancelUnplugFailureOrDisabledTimeout() {
        for stop in ["cancel", "unplug", "failure", "disabled"] {
            let backend = FakeBackend()
            var clock: TimeInterval = 0
            let model = DeviceSetupModel(backend: backend,
                timing: DeviceSetupTiming(choiceTimeout: stop == "disabled" ? 0 : 10), now: { clock })
            model.jackChanged(true)
            model.chooseSmartKey()
            if stop == "cancel" { model.cancel() }
            if stop == "unplug" { backend.isJackConnected = false }
            if stop == "failure" { backend.throwOnWrite = true }
            clock = 10
            model.tick()
            clock = 100
            model.tick()
            #expect(backend.writes.count == (stop == "failure" ? 1 : 0))
            #expect(!model.hasAutomaticOutputChoice)
        }
    }

    @Test func setupFramesFitSmallAndOffsetScreens() {
        let settings = RuntimeSettings()
        let choice = SetupPanelLayout.preferredSize(settings, stage: .choosingType)
        let output = SetupPanelLayout.preferredSize(settings, stage: .choosingOutput)
        #expect(choice.width == output.width)
        #expect(choice.height < output.height)
        for screen in [CGRect(x: 0, y: 40, width: 1440, height: 835),
                       CGRect(x: -1920, y: -300, width: 1920, height: 1050),
                       CGRect(x: 1440, y: 100, width: 320, height: 240)] {
            for margin: CGFloat in [0, 18, 10000] {
                let frame = SetupPanelLayout.frame(size: SetupPanelLayout.preferredSize(settings),
                                                   visibleFrame: screen, margin: margin)
                #expect(screen.contains(frame))
                #expect(frame.width > 0 && frame.height > 0)
            }
        }
    }

    @Test func setupResizeCanBeInterruptedWithoutMovingTheBottomEdge() {
        _ = NSApplication.shared
        let small = CGRect(x: -10000, y: -10000, width: 504, height: 220)
        let large = CGRect(x: -10000, y: -10000, width: 504, height: 392)
        let panel = PopupPanel(contentRect: small, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let resizer = SetupPanelResizer(panel: panel)
        resizer.resize(to: large, animated: true)
        #expect(resizer.isAnimating)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        #expect(panel.frame.origin == small.origin)
        #expect(panel.frame.width == small.width)
        #expect(panel.frame.height > small.height && panel.frame.height < large.height)
        resizer.stop()
        let stopped = panel.frame
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(panel.frame == stopped)
        resizer.resize(to: large, animated: false)
        #expect(panel.frame == large)
        #expect(!resizer.isAnimating)
    }

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

    @Test func activeNonJackOutputLossReconfigures() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        #expect(model.acceptsButtons)
        backend.devices = [headphones]
        backend.defaultUID = "speakers"
        model.audioChanged(backend.audio)
        #expect(model.stage == .choosingOutput)
        #expect(backend.remoteRequests.last == false)
        #expect(backend.guardRequests.last == false)
    }

    @Test func activeJackStealLeavesHIDToBackendGuard() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        #expect(model.acceptsButtons)
        #expect(backend.guardRequests.last == true)
        let writes = backend.writes
        backend.defaultUID = "jack"
        model.audioChanged(backend.audio)
        #expect(model.stage == .active)
        #expect(model.acceptsButtons)
        #expect(backend.remoteRequests.last == true)
        #expect(backend.writes == writes)
    }

    @Test func outputGuardFailureShowsPickerAndCancelStopsRetry() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        #expect(model.acceptsButtons)
        backend.defaultUID = "jack"
        model.outputGuardRestoreFailed(backend.audio)
        #expect(model.stage == .choosingOutput)
        #expect(model.error != nil)
        #expect(backend.remoteRequests.last == false)
        #expect(backend.guardRequests.last == false)
        let writes = backend.writes
        model.cancel()
        model.tick()
        #expect(model.stage == .paused)
        #expect(backend.writes == writes)
        model.reopen()
        #expect(model.stage == .choosingType)
        #expect(!model.hasAutomaticChoice)
    }

    @Test func activateEnablesGuardAndCancelDisablesIt() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        #expect(backend.guardRequests.last == true)
        model.cancel()
        #expect(backend.guardRequests.last == false)
        model.reopen()
        model.chooseSmartKey()
        model.applyOutput()
        #expect(backend.guardRequests.last == true)
        backend.isJackConnected = false
        model.jackChanged(false)
        #expect(backend.guardRequests.last == false)
    }

    @Test func chooseAudioDeviceDisablesGuardBeforeSwitchingToJack() {
        let backend = FakeBackend()
        backend.defaultUID = "bluetooth"
        let model = DeviceSetupModel(backend: backend)
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applyOutput()
        model.reopen()
        #expect(backend.guardRequests.last == false)
        model.chooseAudioDevice()
        #expect(backend.guardRequests.last == false)
        #expect(backend.writes.last == "jack")
        #expect(backend.remoteRequests.last == false)
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
        #expect(settings.doubleClickEnabled == 0)
        #expect(settings.setupTiming.choiceTimeout == 2.5)
        #expect(settings.setupTiming.popupDelay == 0.15)
        #expect(settings.insertionAnimation.duration == 0.9)
        #expect(settings.insertionAnimation.appear == 0.08)
        #expect(settings.insertionAnimation.disappear == 0.16)
        #expect(settings.insertionAnimation.releaseAfter == 0.74)
    }

    @Test func runtimeSettingsParseDoubleClickEnabled() {
        #expect(RuntimeSettings().doubleClickEnabled == 0)
        #expect(RuntimeSettings.parse("doubleClickEnabled = 1").doubleClickEnabled == 1)
        #expect(RuntimeSettings.parse("doubleClickEnabled = 0").doubleClickEnabled == 0)
        #expect(RuntimeSettings.parse("doubleClickEnabled = 2").doubleClickEnabled == 0)
        #expect(RuntimeSettings.parse("doubleClickEnabled = true").doubleClickEnabled == 0)
    }

    @Test func existingConfMergesDoubleClickEnabledFromFactory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let factory = dir.appendingPathComponent("factory.conf")
        let user = dir.appendingPathComponent("user.conf")
        try """
            # factory
            doubleClickEnabled = 0
            doubleClickMs = 450
            """.write(to: factory, atomically: true, encoding: .utf8)
        try """
            # user
            doubleClickMs = 300
            """.write(to: user, atomically: true, encoding: .utf8)
        let inserted = try String(contentsOf: RuntimeConfiguration.ensureFile(at: user, factory: factory), encoding: .utf8)
        let insertedSettings = RuntimeSettings.parse(inserted)
        #expect(insertedSettings.doubleClickEnabled == 0)
        #expect(insertedSettings.doubleClickMs == 300)
        #expect(inserted.contains("doubleClickEnabled = 0"))

        try "doubleClickEnabled = 1\n".write(to: user, atomically: true, encoding: .utf8)
        let kept = try String(contentsOf: RuntimeConfiguration.ensureFile(at: user, factory: factory), encoding: .utf8)
        #expect(RuntimeSettings.parse(kept).doubleClickEnabled == 1)
        #expect(kept.contains("doubleClickEnabled = 1"))
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

    @Test func existingConfMergesNewFactoryKeysAndKeepsUserValues() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let factory = dir.appendingPathComponent("factory.conf")
        let user = dir.appendingPathComponent("user.conf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            # factory
            sidePt = 9
            bubbleRetriggerMs = 120
            """.write(to: factory, atomically: true, encoding: .utf8)
        try """
            # user
            sidePt = 5
            """.write(to: user, atomically: true, encoding: .utf8)
        let url = RuntimeConfiguration.ensureFile(at: user, factory: factory)
        let text = try String(contentsOf: url, encoding: .utf8)
        let settings = RuntimeSettings.parse(text)
        #expect(settings.sidePt == 5)
        #expect(settings.bubbleRetriggerMs == 120)
        #expect(text.contains("bubbleRetriggerMs = 120"))
        #expect(text.contains("# factory"))
    }

    @Test func bubbleRetriggerMsDefaultsAndDropsLegacyRetractCooldown() throws {
        #expect(RuntimeSettings().bubbleRetriggerMs == 20)
        #expect(RuntimeSettings.parse("bubbleRetriggerMs = 50").bubbleRetriggerMs == 50)
        #expect(RuntimeSettings.parse("bubbleRetriggerMs = -1").bubbleRetriggerMs == 20)
        #expect(RuntimeSettings.parse("bubbleRetractCooldownMs = -120").bubbleRetriggerMs == 20)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let factory = dir.appendingPathComponent("factory.conf")
        let user = dir.appendingPathComponent("user.conf")
        try """
            # factory
            sidePt = 9
            bubbleRetriggerMs = 20
            """.write(to: factory, atomically: true, encoding: .utf8)
        try """
            # user
            sidePt = 5
            bubbleRetractCooldownMs = -120
            """.write(to: user, atomically: true, encoding: .utf8)
        let url = RuntimeConfiguration.ensureFile(at: user, factory: factory)
        let text = try String(contentsOf: url, encoding: .utf8)
        let settings = RuntimeSettings.parse(text)
        #expect(settings.sidePt == 5)
        #expect(settings.bubbleRetriggerMs == 20)
        #expect(text.contains("bubbleRetriggerMs = 20"))
        #expect(!text.contains("bubbleRetractCooldownMs"))
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
        let view = NSHostingView(rootView: DeviceSetupView(model: model))
        view.sizingOptions = []
        let frame = NSRect(origin: NSPoint(x: -10000, y: -10000), size: SetupPanelLayout.preferredSize(RuntimeSettings(), stage: .choosingType))
        let window = PopupPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let resizer = SetupPanelResizer(panel: window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for name in ["device-type", "audio-output", "audio-output-dark", "audio-error"] {
            if name == "audio-output" { model.chooseSmartKey() }
            if name == "audio-error" { backend.throwOnWrite = true; model.applyOutput() }
            let target = NSRect(origin: frame.origin, size: SetupPanelLayout.preferredSize(RuntimeSettings(), stage: model.stage,
                                                                                          automaticallySelectingOutput: model.automaticallySelectingOutput))
            resizer.resize(to: target, animated: name == "audio-output")
            window.appearance = NSAppearance(named: name.hasSuffix("-dark") ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.32))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            func inspect(_ node: NSView) {
                if let table = node as? NSTableView {
                    #expect(table.numberOfRows == backend.devices.filter { !$0.isAnalogJack }.count)
                    #expect(table.selectedRow == 0)
                    #expect(table.delegate?.tableView?(table, shouldSelectRow: 0) == true)
                    #expect(table.frame.width > 300)
                    #expect(table.frame.width < view.bounds.width)
                }
                node.subviews.forEach(inspect)
            }
            inspect(view)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/smartKey-\(name).png"))
            #expect(window.frame == target)
            #expect(window.frame.origin == frame.origin)
            #expect(window.frame.width == frame.width)
        }
    }

    @Test func settingsCanChangeActiveOutputWithoutReopeningTypeChoice() {
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.presentationHostForNewFlow = { .settings }
        model.jackChanged(true)
        model.chooseSmartKey()
        model.applySettingsOutput()
        #expect(model.stage == .active)
        model.selectedUID = bluetooth.uid
        #expect(model.canEditSettingsOutput)
        model.applySettingsOutput()
        #expect(model.stage == .active)
        #expect(backend.writes == [speakers.uid, bluetooth.uid])
        model.chooseAudioDevice()
        #expect(!model.canEditSettingsOutput)
        let writes = backend.writes
        model.applySettingsOutput()
        #expect(backend.writes == writes)
    }

    @Test func renderInlineAudioSetup() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-inline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = RuntimeConfiguration()
        let coordinator = try ActionCoordinator(configuration: configuration, directory: directory,
                                               permissions: PermissionsModel(check: { _ in false }))
        coordinator.deviceConnected = true
        coordinator.deviceStatus = "智键"
        let backend = FakeBackend()
        let model = DeviceSetupModel(backend: backend)
        model.presentationHostForNewFlow = { .settings }
        coordinator.deviceSetup = model
        coordinator.onChooseAudioDevice = { model.chooseAudioDevice() }
        coordinator.onChooseSmartKey = { model.chooseSmartKey() }
        model.jackChanged(true)
        model.chooseSmartKey()
        #expect(!coordinator.canUseActions)
        #expect(model.presentationHost == .settings)
        #expect(model.canEditSettingsOutput)
        let view = NSHostingView(rootView: GeneralSettingsView(coordinator: coordinator))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        var tables: [NSTableView] = []
        func inspect(_ node: NSView) {
            if let table = node as? NSTableView { tables.append(table) }
            node.subviews.forEach(inspect)
        }
        inspect(view)
        #expect(tables.count == 1)
        #expect(tables.first?.numberOfRows == 2)
        #expect(model.hasAutomaticOutputChoice)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/smartKey-inline-audio.png"))
        for state in ["active", "audio", "disconnected"] {
            if state == "active" { model.applySettingsOutput() }
            if state == "audio" { model.chooseAudioDevice() }
            if state == "disconnected" { backend.isJackConnected = false; model.jackChanged(false) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            tables.removeAll()
            inspect(view)
            #expect(tables.count == 1)
            #expect(model.canEditSettingsOutput == (state == "active"))
        }
    }
}
