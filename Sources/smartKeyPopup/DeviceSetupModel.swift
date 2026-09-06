import Combine
import Foundation
import SmartKey

protocol DeviceSetupBackend: AnyObject {
    var isJackConnected: Bool { get }
    var audio: SmartKeyAudioSnapshot { get }
    var seizeStatus: SmartKeySeizeStatus { get }
    var seizeDiagnostic: String? { get }
    func setDefaultOutput(uid: String) throws
    func setRemoteEnabled(_ enabled: Bool)
}

extension SmartKeyService: DeviceSetupBackend {}

@MainActor
final class DeviceSetupModel: ObservableObject {
    enum Stage: Equatable {
        case disconnected, choosingType, audioDevice, choosingOutput, applying, applyingAudio
        case activating, active, audioError, remoteError, paused
    }

    @Published private(set) var stage: Stage = .disconnected
    @Published private(set) var remainingSeconds = 10
    @Published private(set) var outputs: [SmartKeyAudioDevice] = []
    @Published var selectedUID: String?
    @Published private(set) var error: String?
    @Published private(set) var automaticallySelectingOutput = false
    @Published private(set) var preferredChoice: DeviceTypeChoice
    @Published private(set) var isWaitingToPresent = false
    var timing: DeviceSetupTiming
    var onInsertion: (() -> Void)?
    var onStageChange: (() -> Void)?

    private let backend: DeviceSetupBackend
    private let now: () -> TimeInterval
    private let choiceStore: DeviceChoiceStoring?
    private(set) var rememberedOutputUID: String?
    private var connected = false
    private var deadline: TimeInterval?
    private var requestedUID: String?
    private var smartKeyWanted = false
    private var presentationDeadline: TimeInterval?

    init(backend: DeviceSetupBackend,
         timing: DeviceSetupTiming = DeviceSetupTiming(),
         choiceStore: DeviceChoiceStoring? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.now = now
        self.timing = timing
        self.choiceStore = choiceStore
        preferredChoice = choiceStore?.lastChoice ?? .smartKey
        remainingSeconds = max(0, Int(ceil(timing.choiceTimeout)))
    }

    var isPresented: Bool {
        !isWaitingToPresent && [.choosingType, .choosingOutput, .applying, .applyingAudio,
         .activating, .audioError, .remoteError].contains(stage)
    }
    var canApply: Bool { stage == .choosingOutput && outputs.contains { $0.uid == selectedUID } }
    var acceptsButtons: Bool { stage == .active && backend.seizeStatus == .seized }
    var hasAutomaticChoice: Bool { stage == .choosingType && deadline != nil }

    func jackChanged(_ inserted: Bool) {
        if !inserted { rememberCurrentOutput(backend.audio) }
        guard inserted != connected else { return }
        connected = inserted
        cancelPendingPresentation()
        deadline = nil
        requestedUID = nil
        error = nil
        selectedUID = nil
        smartKeyWanted = false
        preferredChoice = choiceStore?.lastChoice ?? preferredChoice
        remainingSeconds = Int(ceil(timing.choiceTimeout))
        isWaitingToPresent = inserted && timing.popupDelay > 0
        presentationDeadline = isWaitingToPresent ? now() + timing.popupDelay : nil
        transition(inserted ? .choosingType : .disconnected)
        backend.setRemoteEnabled(false)
        guard inserted else { return }
        rememberCurrentOutput(backend.audio)
        onInsertion?()
        if !isWaitingToPresent { startChoiceCountdown() }
    }

    func chooseAudioDevice() {
        guard connected else { return }
        guard backend.isJackConnected else { jackChanged(false); return }
        rememberChoice(.audioDevice)
        cancelPendingPresentation()
        smartKeyWanted = false
        error = nil
        deadline = nil
        rememberCurrentOutput(backend.audio)
        transition(.applyingAudio)
        backend.setRemoteEnabled(false)
        guard let jack = backend.audio.outputs.first(where: \.isAnalogJack) else {
            fail("耳机端口已不可用，请检查连接后重试。", stage: .audioError)
            return
        }
        beginOutputChange(jack.uid, forAudioDevice: true)
    }

    /// Cancel is separate from selecting audio: it must not reroute sound to the smart key.
    func cancel() {
        cancelPendingPresentation()
        smartKeyWanted = false
        deadline = nil
        requestedUID = nil
        error = nil
        transition(.paused)
        backend.setRemoteEnabled(false)
    }

    func chooseSmartKey() {
        guard connected, stage == .choosingType else { return }
        guard backend.isJackConnected else { jackChanged(false); return }
        rememberChoice(.smartKey)
        cancelPendingPresentation()
        smartKeyWanted = true
        deadline = nil
        configureSmartKeyOutput()
    }

    private func configureSmartKeyOutput() {
        let snapshot = backend.audio
        updateDevices(snapshot)
        automaticallySelectingOutput = outputs.count == 1
        if automaticallySelectingOutput, let device = outputs.first {
            beginOutputChange(device.uid)
        } else {
            // With several choices, history is only a preselection.
            transition(.choosingOutput)
        }
    }

    func reopen() {
        guard connected else { return }
        cancelPendingPresentation()
        preferredChoice = choiceStore?.lastChoice ?? preferredChoice
        smartKeyWanted = false
        deadline = nil
        requestedUID = nil
        error = nil
        transition(.choosingType)
        backend.setRemoteEnabled(false)
    }

    func applyOutput() {
        guard canApply, let uid = selectedUID else { return }
        automaticallySelectingOutput = false
        smartKeyWanted = true
        beginOutputChange(uid)
    }

    private func beginOutputChange(_ uid: String, forAudioDevice: Bool = false) {
        guard backend.isJackConnected else { jackChanged(false); return }
        error = nil
        requestedUID = uid
        deadline = now() + timing.audioSwitchTimeout
        transition(forAudioDevice ? .applyingAudio : .applying)
        do {
            if backend.audio.defaultOutputUID != uid { try backend.setDefaultOutput(uid: uid) }
            audioChanged(backend.audio)
        } catch {
            let message: String
            switch error as? SmartKeyAudioError {
            case .unknownUID: message = "所选音频设备已断开，请连接设备后重试。"
            case .notSelectable: message = "此设备当前无法用作系统音频输出，请重试或选择其他设备。"
            case .hardware, .none: message = "系统未能切换音频输出，请检查设备连接后重试。"
            }
            fail(message, stage: forAudioDevice ? .audioError : .choosingOutput)
        }
    }

    func audioChanged(_ snapshot: SmartKeyAudioSnapshot) {
        updateDevices(snapshot)
        rememberCurrentOutput(snapshot)
        if stage == .applying || stage == .applyingAudio {
            guard let uid = requestedUID, snapshot.defaultOutputUID == uid,
                  snapshot.outputs.contains(where: { $0.uid == uid }) else { return }
            guard backend.isJackConnected else { jackChanged(false); return }
            deadline = nil
            if stage == .applyingAudio {
                transition(.audioDevice)
            } else {
                activateRemote()
            }
        } else if stage == .active || stage == .activating || stage == .remoteError {
            if !outputs.contains(where: { $0.uid == snapshot.defaultOutputUID }) {
                // Release before restoring the audio route; queued input stays gated.
                transition(.applying)
                backend.setRemoteEnabled(false)
                configureSmartKeyOutput()
            }
        }
    }

    private func activateRemote() {
        error = nil
        deadline = now() + timing.hidConnectionNotice
        transition(.activating)
        backend.setRemoteEnabled(true)
        seizeChanged(backend.seizeStatus)
    }

    func retryRemote() {
        guard connected, smartKeyWanted else { return }
        guard backend.isJackConnected else { jackChanged(false); return }
        deadline = nil
        transition(.applying)
        backend.setRemoteEnabled(false)
        let snapshot = backend.audio
        if snapshot.outputs.contains(where: { $0.uid == snapshot.defaultOutputUID && !$0.isAnalogJack }) {
            activateRemote()
        } else {
            configureSmartKeyOutput()
        }
    }

    func seizeChanged(_ status: SmartKeySeizeStatus) {
        guard smartKeyWanted, stage == .activating || stage == .active || stage == .remoteError else { return }
        switch status {
        case .seized:
            deadline = nil
            error = nil
            transition(.active)
        case .failed:
            deadline = nil
            error = backend.seizeDiagnostic ?? "无法独占智键，请关闭其他智键程序后重试。"
            transition(.remoteError)
        case .waiting, .idle:
            if stage == .active {
                deadline = now() + timing.hidConnectionNotice
                transition(.activating)
            }
        }
    }

    func tick() {
        if isWaitingToPresent {
            guard let presentationDeadline, now() >= presentationDeadline else { return }
            guard backend.isJackConnected else { jackChanged(false); return }
            cancelPendingPresentation()
            startChoiceCountdown()
            onStageChange?()
        }
        if stage == .choosingType, let deadline {
            remainingSeconds = max(0, Int(ceil(deadline - now())))
            if now() >= deadline { choosePreferredDevice() }
        } else if stage == .applying || stage == .applyingAudio || stage == .activating {
            audioChanged(backend.audio)
            if stage == .activating { seizeChanged(backend.seizeStatus) }
            if let deadline, now() >= deadline {
                if stage == .activating {
                    self.deadline = nil
                    error = "正在等待智键线控。可尝试按一下智键或重新插入设备。"
                    // Keep HID discovery alive: a delayed device can recover automatically.
                    onStageChange?()
                } else {
                    fail("音频输出切换未生效，请检查设备后重试。",
                         stage: stage == .applyingAudio ? .audioError : .choosingOutput)
                }
            }
        }
    }

    func focusChoice(_ choice: DeviceTypeChoice) {
        guard stage == .choosingType else { return }
        preferredChoice = choice
    }

    func choosePreferredDevice() {
        switch preferredChoice {
        case .audioDevice: chooseAudioDevice()
        case .smartKey: chooseSmartKey()
        }
    }

    private func rememberChoice(_ choice: DeviceTypeChoice) {
        preferredChoice = choice
        choiceStore?.lastChoice = choice
    }

    private func startChoiceCountdown() {
        remainingSeconds = Int(ceil(timing.choiceTimeout))
        deadline = timing.choiceTimeout > 0 ? now() + timing.choiceTimeout : nil
    }

    private func cancelPendingPresentation() {
        presentationDeadline = nil
        isWaitingToPresent = false
    }

    private func rememberCurrentOutput(_ snapshot: SmartKeyAudioSnapshot) {
        guard let device = snapshot.outputs.first(where: { $0.uid == snapshot.defaultOutputUID && !$0.isAnalogJack }),
              rememberedOutputUID != device.uid else { return }
        rememberedOutputUID = device.uid
    }

    private func updateDevices(_ snapshot: SmartKeyAudioSnapshot) {
        outputs = snapshot.outputs.filter { !$0.isAnalogJack }
        if !outputs.contains(where: { $0.uid == selectedUID }) {
            selectedUID = outputs.first { $0.uid == snapshot.defaultOutputUID }?.uid
                ?? outputs.first { $0.uid == rememberedOutputUID }?.uid
                ?? outputs.first { $0.transport == .builtIn }?.uid
                ?? outputs.first?.uid
        }
    }

    private func fail(_ message: String, stage: Stage) {
        deadline = nil
        requestedUID = nil
        error = message
        transition(stage)
        backend.setRemoteEnabled(false)
    }

    private func transition(_ next: Stage) {
        guard stage != next else { return }
        stage = next
        onStageChange?()
    }
}
