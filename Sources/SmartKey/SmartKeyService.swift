import Foundation

public final class SmartKeyService {
    public var onJackChange: ((Bool) -> Void)?
    public var onAudioChange: ((SmartKeyAudioSnapshot) -> Void)?
    public var onButton: ((SmartKeyButtonPhase) -> Void)?
    public var onGesture: ((SmartKeyGestureEvent) -> Void)?
    public var onSeizeStatusChange: ((SmartKeySeizeStatus) -> Void)?

    public var configuration: SmartKeyConfiguration {
        didSet { recognizer.applyConfiguration(configuration) }
    }

    public var isRunning: Bool { running }
    public var isJackConnected: Bool { jack.isConnected }
    public var audio: SmartKeyAudioSnapshot { audioGraph.snapshot }
    public var isRemoteEnabled: Bool { remoteWanted }
    public var seizeStatus: SmartKeySeizeStatus { hid.seizeStatus }
    public var isButtonPressed: Bool { recognizer.isButtonPressed }

    private let jack = JackWatcher()
    private let audioGraph = AudioGraph()
    private let hid = HIDWatcher()
    private let recognizer: GestureRecognizer

    private var running = false
    private var remoteWanted = false

    public init(configuration: SmartKeyConfiguration = .default) {
        self.configuration = configuration
        recognizer = GestureRecognizer(configuration: configuration)
        jack.onChange = { [weak self] connected in
            self?.handleJack(connected)
        }
        audioGraph.onChange = { [weak self] snapshot in
            self?.emitOnMain { self?.onAudioChange?(snapshot) }
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
        if configuration.emitJackOnStart, configuration.enabledEvents.contains(.jack) {
            let connected = jack.isConnected
            emitOnMain { [weak self] in self?.onJackChange?(connected) }
        }
        applyRemote()
    }

    public func stop() {
        guard running else { return }
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
