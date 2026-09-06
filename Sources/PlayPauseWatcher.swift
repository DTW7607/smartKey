import Foundation
import IOKit.hid

enum PlayPauseGesture {
    case pending
    case single
    case double
    case longPress
}

/// 独占内置 3.5mm 线控 HID（AppleCS42L84Mikey / Transport=Audio）。
/// seize 成功后，播放/音量都不会进 WindowServer；失败则不启用按键，避免共享监听泄漏。
final class PlayPauseWatcher {
    private let manager: IOHIDManager
    private var seized: [IOHIDDevice] = []
    var onGesture: ((PlayPauseGesture, Int) -> Void)?
    private let config: GestureConfig

    private var isDown = false
    private var longPressFired = false
    private var awaitingSecondClick = false
    private var ignoreUpAfterDouble = false
    private var longPressWork: DispatchWorkItem?
    private var singleClickWork: DispatchWorkItem?
    private var pendingCount = 0
    private var singleCount = 0
    private var doubleCount = 0
    private var longCount = 0

    private static let seizeOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)

    init(config: GestureConfig) {
        self.config = config
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

        _ = IOHIDManagerOpen(manager, Self.seizeOptions)
    }

    private func handle(device: IOHIDDevice, added: Bool) {
        if added {
            let kr = IOHIDDeviceOpen(device, Self.seizeOptions)
            if kr == kIOReturnSuccess {
                if !contains(device) { seized.append(device) }
            } else {
                IOHIDDeviceClose(device, 0)
            }
        } else {
            remove(device)
            IOHIDDeviceClose(device, 0)
        }
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard contains(device) else { return }

        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        guard page == 0x0C, usage == 0xCD else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        if pressed { handleDown() } else { handleUp() }
    }

    private func handleDown() {
        isDown = true
        if awaitingSecondClick {
            cancel(&singleClickWork)
            cancel(&longPressWork)
            awaitingSecondClick = false
            ignoreUpAfterDouble = true
            longPressFired = false
            doubleCount += 1
            onGesture?(.double, doubleCount)
            return
        }

        longPressFired = false
        ignoreUpAfterDouble = false
        cancel(&longPressWork)
        pendingCount += 1
        onGesture?(.pending, pendingCount)
        let work = DispatchWorkItem { [weak self] in
            self?.fireLongPress()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.longPressDuration, execute: work)
    }

    private func handleUp() {
        isDown = false
        cancel(&longPressWork)
        if ignoreUpAfterDouble {
            ignoreUpAfterDouble = false
            return
        }
        if longPressFired {
            longPressFired = false
            return
        }
        awaitingSecondClick = true
        let work = DispatchWorkItem { [weak self] in
            self?.fireSingle()
        }
        singleClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.doubleClickGap, execute: work)
    }

    private func fireSingle() {
        awaitingSecondClick = false
        singleCount += 1
        onGesture?(.single, singleCount)
    }

    private func fireLongPress() {
        guard isDown, !longPressFired else { return }
        longPressFired = true
        awaitingSecondClick = false
        ignoreUpAfterDouble = false
        cancel(&singleClickWork)
        longCount += 1
        onGesture?(.longPress, longCount)
    }

    private func cancel(_ work: inout DispatchWorkItem?) {
        work?.cancel()
        work = nil
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
}
