import Foundation
import IOKit.hid

/// Enumerate only built-in audio consumer controls. Each device is opened exactly
/// once with seize options; no shared input callbacks are installed on failure.
final class HIDWatcher {
    var onPressed: ((Bool) -> Void)?
    var onSeizeStatusChange: ((SmartKeySeizeStatus) -> Void)?

    private var manager: IOHIDManager?
    private var seized: [IOHIDDevice] = []
    private var discoveryTimer: Timer?
    private(set) var seizeStatus: SmartKeySeizeStatus = .idle
    private(set) var diagnostic: String?
    private var lastOpenError: IOReturn?
    var isRunning: Bool { manager != nil }
    var isPermissionDenied: Bool {
        lastOpenError == kIOReturnNotPermitted || lastOpenError == kIOReturnNotPrivileged
    }
    private static let runLoopMode = CFRunLoopMode.commonModes.rawValue

    func start() {
        guard manager == nil else { return }
        // Recreate the manager on every session so old enumeration state and queued
        // matching callbacks cannot strand a stop/start cycle in .waiting.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        diagnostic = nil
        lastOpenError = nil
        setStatus(.waiting)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        let matching: [String: Any] = [
            kIOHIDTransportKey as String: "Audio",
            kIOHIDPrimaryUsagePageKey as String: 0x0C,
            kIOHIDPrimaryUsageKey as String: 0x01,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), Self.runLoopMode)
        // IndependentDevices means the manager does not open/schedule its devices.
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else {
            stop()
            reportFailure(result)
            return
        }
        discoverExistingDevices()
        guard self.manager != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.discoverExistingDevices()
        }
        discoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        guard let manager else { return }
        self.manager = nil
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        for device in seized { close(device) }
        seized.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), Self.runLoopMode)
        IOHIDManagerClose(manager, 0)
        diagnostic = nil
        lastOpenError = nil
        setStatus(.idle)
    }

    deinit { stop() }

    private func discoverExistingDevices() {
        guard let manager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for device in devices {
            guard self.manager != nil else { return }
            handle(device: device, added: true)
        }
    }

    private func handle(device: IOHIDDevice, added: Bool) {
        guard manager != nil else { return }
        if added {
            guard !contains(device) else { return }
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard result == kIOReturnSuccess else {
                if seized.isEmpty { reportFailure(result) }
                return
            }
            seized.append(device)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputValueCallback(device, Self.inputValue, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), Self.runLoopMode)
            diagnostic = nil
            lastOpenError = nil
            setStatus(.seized)
        } else if contains(device) {
            close(device)
            seized.removeAll { CFEqual($0, device) }
            if seized.isEmpty { setStatus(.waiting) }
        }
    }

    private func close(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), Self.runLoopMode)
        IOHIDDeviceClose(device, 0)
    }

    private func reportFailure(_ result: IOReturn) {
        let changedFailure = seizeStatus == .failed && result != lastOpenError
        switch result {
        case kIOReturnExclusiveAccess, kIOReturnBusy:
            diagnostic = "智键正被其他程序占用，请退出其他智键程序后重试。"
        case kIOReturnNotPermitted, kIOReturnNotPrivileged:
            diagnostic = "系统拒绝访问线控，请检查系统设置中的输入监控权限后重试。"
        default:
            diagnostic = "无法打开智键线控（\(String(format: "0x%08X", UInt32(bitPattern: result)))），请重新插入后重试。"
        }
        if result != lastOpenError {
            fputs("[SmartKey] HID open failed: \(String(format: "0x%08X", UInt32(bitPattern: result)))\n", stderr)
        }
        lastOpenError = result
        setStatus(.failed)
        // A busy device may subsequently fail for permission reasons without
        // changing the coarse status. Publish that new diagnostic as well.
        if changedFailure { onSeizeStatusChange?(.failed) }
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard contains(IOHIDElementGetDevice(element)),
              IOHIDElementGetUsagePage(element) == 0x0C,
              IOHIDElementGetUsage(element) == 0xCD else { return }
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

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handle(device: device, added: true)
    }
    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handle(device: device, added: false)
    }
    private static let inputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        Unmanaged<HIDWatcher>.fromOpaque(context).takeUnretainedValue().handle(value: value)
    }
}
