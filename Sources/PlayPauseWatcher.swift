import Foundation
import IOKit.hid

/// 独占内置 3.5mm 线控 HID（AppleCS42L84Mikey / Transport=Audio）。
/// seize 成功后，播放/音量都不会进 WindowServer；失败则不启用按键，避免共享监听泄漏。
final class PlayPauseWatcher {
    private let manager: IOHIDManager
    private var seized: [IOHIDDevice] = []
    private var count = 0
    var onPress: ((Int) -> Void)?

    private static let seizeOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        let matching: [String: Any] = [
            kIOHIDTransportKey as String: "Audio",
            kIOHIDPrimaryUsagePageKey as String: 0x0C,
            kIOHIDPrimaryUsageKey as String: 0x01,
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

        let open = IOHIDManagerOpen(manager, Self.seizeOptions)
        if open != kIOReturnSuccess {
            print("[hid] IOHIDManagerOpen(seize) 失败: \(Self.ioReturnHex(open))")
            print("[hid] 不启用共享监听，避免按键泄漏到系统")
        }
    }

    private func handle(device: IOHIDDevice, added: Bool) {
        let product = Self.stringProperty(device, kIOHIDProductKey) ?? "?"
        let transport = Self.stringProperty(device, kIOHIDTransportKey) ?? "?"
        if added {
            let kr = IOHIDDeviceOpen(device, Self.seizeOptions)
            if kr == kIOReturnSuccess {
                if !contains(device) { seized.append(device) }
                print("[hid] 已独占 \(product) transport=\(transport) — 系统收不到此设备按键")
            } else {
                print("[hid] 独占失败 \(product) \(Self.ioReturnHex(kr)) — 按键不启用（防止泄漏）")
                IOHIDDeviceClose(device, 0)
            }
        } else {
            remove(device)
            IOHIDDeviceClose(device, 0)
            print("[hid] 已释放 \(product)")
        }
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard contains(device) else { return }

        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard page == 0x0C, usage == 0xCD else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }
        count += 1
        onPress?(count)
    }

    private func contains(_ device: IOHIDDevice) -> Bool {
        seized.contains { CFEqual($0, device) }
    }

    private func remove(_ device: IOHIDDevice) {
        seized.removeAll { CFEqual($0, device) }
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

    private static func ioReturnHex(_ value: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}
