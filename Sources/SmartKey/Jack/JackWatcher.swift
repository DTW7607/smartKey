import CoreAudio
import Foundation
import IOKit

/// 插拔用事件，不轮询。
/// 只认内置 3.5mm 的 HAL UID `BuiltInHeadphoneOutputDevice`，
/// 排除蓝牙 / USB / USB-C 转接头。
final class JackWatcher {
    var onChange: ((Bool) -> Void)?

    private var codec: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var lastConnected: Bool?
    private let queue = DispatchQueue(label: "smartKey.jack")
    private var listening = false

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
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultOutListener: AudioObjectPropertyListenerBlock?

    var isConnected: Bool { Self.analogJackPresent() }

    func start() {
        guard !listening else { return }
        listenHAL()
        listenCodec()
        lastConnected = Self.analogJackPresent()
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
        devicesListener = nil
        defaultOutListener = nil

        if interest != 0 {
            IOObjectRelease(interest)
            interest = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if codec != 0 {
            IOObjectRelease(codec)
            codec = 0
        }
        lastConnected = nil
    }

    deinit { stop() }

    private func listenHAL() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit()
        }
        let defaultOutListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emit()
        }
        self.devicesListener = devicesListener
        self.defaultOutListener = defaultOutListener
        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, queue, devicesListener)
        AudioObjectAddPropertyListenerBlock(system, &defaultOutAddress, queue, defaultOutListener)
    }

    private func listenCodec() {
        codec = Self.findCodec()
        guard codec != 0 else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = IOServiceAddInterestNotification(
            port,
            codec,
            kIOGeneralInterest,
            Self.interestCallback,
            context,
            &interest
        )
    }

    private static let interestCallback: IOServiceInterestCallback = { context, _, messageType, _ in
        guard let context else { return }
        let watcher = Unmanaged<JackWatcher>.fromOpaque(context).takeUnretainedValue()
        _ = messageType
        watcher.emit()
    }

    private func emit() {
        let connected = Self.analogJackPresent()
        guard connected != lastConnected else { return }
        lastConnected = connected
        onChange?(connected)
    }

    /// 仅当内置模拟插孔输出节点存在。UID 由 Apple 固定，与界面语言无关。
    private static func analogJackPresent() -> Bool {
        for id in HAL.listDevices() {
            guard HAL.deviceUID(id) == AnalogJack.outputUID else { continue }
            guard HAL.transport(id) == AnalogJack.transport else { continue }
            return true
        }
        return false
    }

    private static func findCodec() -> io_object_t {
        let classes = [
            "AppleCS42L84Audio",
            "AppleCS42L83Audio",
            "AppleCS42L42Audio",
            "AppleCS42L77Audio",
        ]
        for name in classes {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(name), &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            let service = IOIteratorNext(iterator)
            if service != 0 { return service }
        }
        return 0
    }
}
