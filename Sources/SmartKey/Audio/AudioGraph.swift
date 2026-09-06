import CoreAudio
import Foundation

final class AudioGraph {
    var onChange: ((SmartKeyAudioSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "smartKey.audio")
    private var listening = false
    private var lastSnapshot: SmartKeyAudioSnapshot?

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultOutAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutListener: AudioObjectPropertyListenerBlock?
    private var defaultInListener: AudioObjectPropertyListenerBlock?

    var snapshot: SmartKeyAudioSnapshot { Self.capture() }

    func start() {
        guard !listening else { return }
        listen()
        lastSnapshot = Self.capture()
        listening = true
    }

    func stop() {
        guard listening else { return }
        listening = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let listener = devicesListener {
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, queue, listener)
        }
        if let listener = defaultOutListener {
            AudioObjectRemovePropertyListenerBlock(system, &defaultOutAddress, queue, listener)
        }
        if let listener = defaultInListener {
            AudioObjectRemovePropertyListenerBlock(system, &defaultInAddress, queue, listener)
        }
        devicesListener = nil
        defaultOutListener = nil
        defaultInListener = nil
        lastSnapshot = nil
    }

    deinit { stop() }

    func setDefaultOutput(uid: String) throws {
        try setDefault(uid: uid, scope: kAudioDevicePropertyScopeOutput, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func setDefaultInput(uid: String) throws {
        try setDefault(uid: uid, scope: kAudioDevicePropertyScopeInput, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func setDefault(uid: String, scope: AudioObjectPropertyScope, selector: AudioObjectPropertySelector) throws {
        guard let id = HAL.findDevice(uid: uid) else {
            throw SmartKeyAudioError.unknownUID(uid)
        }
        guard HAL.canBeDefault(id, scope: scope) else {
            throw SmartKeyAudioError.notSelectable(uid)
        }
        let status = HAL.setDefaultDevice(id, selector: selector)
        guard status == noErr else {
            throw SmartKeyAudioError.hardware(status)
        }
    }

    private func listen() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit()
        }
        let defaultOutListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit()
        }
        let defaultInListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit()
        }
        self.devicesListener = devicesListener
        self.defaultOutListener = defaultOutListener
        self.defaultInListener = defaultInListener
        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, queue, devicesListener)
        AudioObjectAddPropertyListenerBlock(system, &defaultOutAddress, queue, defaultOutListener)
        AudioObjectAddPropertyListenerBlock(system, &defaultInAddress, queue, defaultInListener)
    }

    private func emit() {
        let snapshot = Self.capture()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?(snapshot)
    }

    static func capture() -> SmartKeyAudioSnapshot {
        var outputs: [SmartKeyAudioDevice] = []
        var inputs: [SmartKeyAudioDevice] = []
        var seenOut = Set<String>()
        var seenIn = Set<String>()

        for id in HAL.listDevices() {
            guard let uid = HAL.deviceUID(id) else { continue }
            let name = HAL.deviceName(id) ?? uid
            let transportRaw = HAL.transport(id) ?? 0
            let transport = Self.mapTransport(transportRaw)
            let analog = AnalogJack.isJack(uid) && transportRaw == AnalogJack.transport

            let outOK = HAL.canBeDefault(id, scope: kAudioDevicePropertyScopeOutput)
            let inOK = HAL.canBeDefault(id, scope: kAudioDevicePropertyScopeInput)

            if outOK, seenOut.insert(uid).inserted {
                outputs.append(SmartKeyAudioDevice(uid: uid, name: name, transport: transport, isAnalogJack: analog && AnalogJack.isOutput(uid)))
            }
            if inOK, seenIn.insert(uid).inserted {
                inputs.append(SmartKeyAudioDevice(uid: uid, name: name, transport: transport, isAnalogJack: analog && AnalogJack.isInput(uid)))
            }
        }

        let defaultOut = HAL.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice).flatMap(HAL.deviceUID)
        let defaultIn = HAL.defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice).flatMap(HAL.deviceUID)
        return SmartKeyAudioSnapshot(
            outputs: outputs,
            inputs: inputs,
            defaultOutputUID: defaultOut,
            defaultInputUID: defaultIn
        )
    }

    private static func mapTransport(_ value: UInt32) -> SmartKeyAudioTransport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }
}
