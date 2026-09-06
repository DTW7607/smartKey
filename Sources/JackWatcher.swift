import CoreAudio
import Foundation
import IOKit

/// 插拔用事件，不轮询。
/// 只认内置 3.5mm 的 HAL UID `BuiltInHeadphoneOutputDevice`，
/// 排除蓝牙 / USB / USB-C 转接头。
final class JackWatcher {
    private var codec: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var lastConnected: Bool?
    private let queue = DispatchQueue(label: "smartKey.jack")
    var onChange: ((Bool) -> Void)?

    func start() {
        listenHAL()
        listenCodec()
        emit(initial: true)
    }

    deinit {
        if interest != 0 { IOObjectRelease(interest) }
        if codec != 0 { IOObjectRelease(codec) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
    }

    private func listenHAL() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(system, &devices, queue) { [weak self] _, _ in
            self?.emit(initial: false)
        }
        AudioObjectAddPropertyListenerBlock(system, &dOut, queue) { [weak self] _, _ in
            self?.emit(initial: false)
        }
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
        // 0xE0000130 = kIOMessageServicePropertyChange；其它消息也重读一次无害
        _ = messageType
        watcher.emit(initial: false)
    }

    private func emit(initial: Bool) {
        let connected = Self.analogJackPresent()
        if initial {
            lastConnected = connected
            return
        }
        guard connected != lastConnected else { return }
        lastConnected = connected
        onChange?(connected)
    }

    /// 仅当内置模拟插孔输出节点存在。UID 由 Apple 固定，与界面语言无关。
    private static let analogJackUID = "BuiltInHeadphoneOutputDevice"
    private static let builtInTransport: UInt32 = 0x626C_746E // 'bltn'

    private static func analogJackPresent() -> Bool {
        for id in listDevices() {
            guard deviceUID(id) == analogJackUID else { continue }
            guard transport(id) == builtInTransport else { continue }
            return true
        }
        return false
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr else {
            return nil
        }
        return cf?.takeUnretainedValue() as String?
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func listDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
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
