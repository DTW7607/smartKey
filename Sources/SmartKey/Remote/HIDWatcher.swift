import Foundation
import IOKit.hid

/// 独占内置 3.5mm 线控 HID（AppleCS42L84Mikey / Transport=Audio）。
/// seize 成功后，播放/音量都不会进 WindowServer；失败则不启用按键，避免共享监听泄漏。
final class HIDWatcher {
    var onPressed: ((Bool) -> Void)?
    var onSeizeStatusChange: ((SmartKeySeizeStatus) -> Void)?

    private let manager: IOHIDManager
    private var seized: [IOHIDDevice] = []
    private var running = false
    private(set) var seizeStatus: SmartKeySeizeStatus = .idle

    var isRunning: Bool { running }

    private static let seizeOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        guard !running else { return }
        running = true
        setStatus(.waiting)

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

        let kr = IOHIDManagerOpen(manager, Self.seizeOptions)
        if kr != kIOReturnSuccess {
            teardown(status: .failed)
        }
    }

    func stop() {
        guard running else { return }
        teardown(status: .idle)
    }

    deinit { stop() }

    private func teardown(status: SmartKeySeizeStatus) {
        running = false
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        for device in seized {
            IOHIDDeviceClose(device, 0)
        }
        seized.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, 0)
        setStatus(status)
    }

    private func handle(device: IOHIDDevice, added: Bool) {
        guard running else { return }
        if added {
            let kr = IOHIDDeviceOpen(device, Self.seizeOptions)
            if kr == kIOReturnSuccess {
                if !contains(device) { seized.append(device) }
                setStatus(.seized)
            } else {
                IOHIDDeviceClose(device, 0)
                if seized.isEmpty { setStatus(.failed) }
            }
        } else {
            remove(device)
            IOHIDDeviceClose(device, 0)
            if seized.isEmpty {
                setStatus(running ? .waiting : .idle)
            }
        }
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard contains(device) else { return }

        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard page == 0x0C, usage == 0xCD else { return }
        onPressed?(IOHIDValueGetIntegerValue(value) != 0)
    }

    private func setStatus(_ status: SmartKeySeizeStatus) {
        guard seizeStatus != status else { return }
        seizeStatus = status
        onSeizeStatusChange?(status)
    }

    private func contains(_ device: IOHIDDevice) -> Bool {
        seized.contains { CFEqual($0, device) }
    }

    private func remove(_ device: IOHIDDevice) {
        seized.removeAll { CFEqual($0, device) }
    }

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(device: device, added: true)
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(device: device, added: false)
    }

    private static let inputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue()
            .handle(value: value)
    }
}
