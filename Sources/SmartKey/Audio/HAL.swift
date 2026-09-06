import CoreAudio
import Foundation

enum HAL {
    static func listDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        cfString(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        cfString(id, kAudioObjectPropertyName) ?? cfString(id, kAudioDevicePropertyDeviceNameCFString)
    }

    static func transport(_ id: AudioDeviceID) -> UInt32? {
        uInt32(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
    }

    static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0, id != kAudioObjectUnknown else {
            return nil
        }
        return id
    }

    static func setDefaultDevice(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value
        )
    }

    static func canBeDefault(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        uInt32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope).map { $0 != 0 } ?? false
    }

    static func findDevice(uid: String) -> AudioDeviceID? {
        for id in listDevices() {
            if deviceUID(id) == uid { return id }
        }
        return nil
    }

    private static func cfString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    private static func uInt32(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
