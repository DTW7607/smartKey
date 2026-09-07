import Foundation

public final class SmartKeyService {
    public var onJackChange: ((Bool) -> Void)?
    public var onAudioChange: ((SmartKeyAudioSnapshot) -> Void)?
    public var onButton: ((SmartKeyButtonPhase) -> Void)?
    public var onGesture: ((SmartKeyGestureEvent) -> Void)?
    public var onSeizeStatusChange: ((SmartKeySeizeStatus) -> Void)?
    public var onOutputGuardRestoreFailed: ((SmartKeyAudioSnapshot) -> Void)?

    public var configuration: SmartKeyConfiguration {
        didSet { recognizer.applyConfiguration(configuration) }
    }

    public var isRunning: Bool { running }
    public var isJackConnected: Bool { jack.isConnected }
    public var audio: SmartKeyAudioSnapshot { audioGraph.snapshot }
    public var isRemoteEnabled: Bool { remoteWanted }
    public var isOutputGuardEnabled: Bool { outputGuard.isEnabled }
    public var lastLegalOutputUID: String? { outputGuard.lastLegalOutputUID }
    public var seizeStatus: SmartKeySeizeStatus { hid.seizeStatus }
    public var seizeDiagnostic: String? { hid.diagnostic }
    public var isButtonPressed: Bool { recognizer.isButtonPressed }

    private let jack = JackWatcher()
    private let audioGraph = AudioGraph()
    private let hid = HIDWatcher()
    private let recognizer: GestureRecognizer
    private let outputGuard = AudioOutputGuard()

    private var running = false
    private var remoteWanted = false
    private var restoreWatchdog: DispatchWorkItem?

    public init(configuration: SmartKeyConfiguration = .default) {
        self.configuration = configuration
        recognizer = GestureRecognizer(configuration: configuration)
        jack.onChange = { [weak self] connected in
            self?.handleJack(connected)
        }
        outputGuard.setDefault = { [weak self] uid in
            try self?.audioGraph.setDefaultOutput(uid: uid)
        }
        audioGraph.onChange = { [weak self] snapshot in
            self?.emitOnMain { self?.applyOutputGuard(snapshot) }
        }
        hid.onPressed = { [weak self] pressed in
            self?.recognizer.handle(pressed: pressed)
        }
        hid.onSeizeStatusChange = { [weak self] status in
            if status == .waiting || status == .idle {
                self?.recognizer.reset()
            }
            self?.emitOnMain { self?.onSeizeStatusChange?(status) }
        }
        recognizer.onButton = { [weak self] phase in
            self?.onButton?(phase)
        }
        recognizer.onGesture = { [weak self] event in
            self?.onGesture?(event)
        }
    }

    deinit { stop() }

    public func start() {
        guard !running else { return }
        running = true
        jack.start()
        audioGraph.start()
        outputGuard.handle(audioGraph.snapshot)
        if configuration.emitJackOnStart, configuration.enabledEvents.contains(.jack) {
            let connected = jack.isConnected
            emitOnMain { [weak self] in self?.onJackChange?(connected) }
        }
        applyRemote()
    }

    public func stop() {
        guard running else { return }
        restoreWatchdog?.cancel()
        restoreWatchdog = nil
        outputGuard.setEnabled(false)
        if hid.isRunning { hid.stop() }
        audioGraph.stop()
        jack.stop()
        recognizer.reset()
        recognizer.resetCounts()
        running = false
    }

    public func setRemoteEnabled(_ enabled: Bool) {
        remoteWanted = enabled
        guard running else { return }
        applyRemote()
    }

    public func setOutputGuardEnabled(_ enabled: Bool) {
        outputGuard.setEnabled(enabled)
        if !enabled {
            restoreWatchdog?.cancel()
            restoreWatchdog = nil
            return
        }
        applyOutputGuard(audioGraph.snapshot)
    }

    public func setDefaultOutput(uid: String) throws {
        try audioGraph.setDefaultOutput(uid: uid)
    }

    public func setDefaultInput(uid: String) throws {
        try audioGraph.setDefaultInput(uid: uid)
    }

    private func applyRemote() {
        onMain {
            if self.remoteWanted {
                if !self.hid.isRunning { self.hid.start() }
            } else if self.hid.isRunning {
                self.hid.stop()
                self.recognizer.reset()
            }
        }
    }

    private func applyOutputGuard(_ snapshot: SmartKeyAudioSnapshot) {
        switch outputGuard.handle(snapshot) {
        case .emit:
            restoreWatchdog?.cancel()
            restoreWatchdog = nil
            onAudioChange?(snapshot)
        case .swallow:
            if restoreWatchdog == nil { scheduleRestoreWatchdog() }
        case .failed:
            restoreWatchdog?.cancel()
            restoreWatchdog = nil
            onOutputGuardRestoreFailed?(snapshot)
        }
    }

    private func scheduleRestoreWatchdog() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreWatchdog = nil
            self.applyOutputGuard(self.audioGraph.snapshot)
        }
        restoreWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + outputGuard.restoreTimeout, execute: work)
    }

    private func handleJack(_ connected: Bool) {
        if !connected {
            onMain { self.recognizer.reset() }
        }
        guard configuration.enabledEvents.contains(.jack) else { return }
        emitOnMain { [weak self] in self?.onJackChange?(connected) }
    }

    private func emitOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}
