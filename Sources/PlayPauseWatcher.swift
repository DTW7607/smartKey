import Foundation
import IOKit.hid

/// 只监听内置模拟插孔线控的 Play/Pause（HID Consumer 0x0C:0xCD）。
/// 匹配 Transport=Audio 的 Consumer Control，避免键盘/蓝牙媒体键。
final class PlayPauseWatcher {
    private let manager: IOHIDManager
    private var count = 0
    var onPress: ((Int) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        let matching: [String: Any] = [
            kIOHIDTransportKey as String: "Audio",
            kIOHIDPrimaryUsagePageKey as String: 0x0C, // Consumer
            kIOHIDPrimaryUsageKey as String: 0x01,     // Consumer Control
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputValue, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let open = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if open != kIOReturnSuccess {
            print("[hid] IOHIDManagerOpen 失败: \(open)")
        } else {
            print("[hid] 已开始监听 Headset Play/Pause (listen-only，不 seize)")
        }
    }

    private func handle(device: IOHIDDevice, added: Bool) {
        let product = Self.stringProperty(device, kIOHIDProductKey) ?? "?"
        let transport = Self.stringProperty(device, kIOHIDTransportKey) ?? "?"
        print("[hid] 设备\(added ? "出现" : "消失"): \(product) transport=\(transport)")
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard page == 0x0C, usage == 0xCD else { return } // Consumer Play/Pause
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        guard pressed else { return }
        count += 1
        onPress?(count)
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<PlayPauseWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(device: device, added: true)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<PlayPauseWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(device: device, added: false)
    }

    private static let inputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        Unmanaged<PlayPauseWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(value: value)
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (raw as? String) ?? "\(raw)"
    }
}
