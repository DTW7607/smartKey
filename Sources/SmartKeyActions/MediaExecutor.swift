import AppKit
import CoreAudio

public enum MediaOperation: String, CaseIterable, Identifiable, Sendable {
    case playPause, previous, next, volumeUp, volumeDown, mute
    public var id: String { rawValue }
    public var title: String {
        switch self { case .playPause: return "播放暂停"; case .previous: return "上一首"; case .next: return "下一首"
        case .volumeUp: return "音量增加"; case .volumeDown: return "音量减少"; case .mute: return "输出静音" }
    }
}

@MainActor
public final class MediaActionProvider: ActionProvider {
    public let typeID = "media"
    public init() {}
    public func capabilities(for action: ActionDefinition) -> ActionCapabilities {
        let readable = ["volumeUp", "volumeDown", "mute"].contains(action.parameters["operation"] ?? "")
        return ActionCapabilities(permissions: readable ? [] : ["辅助功能"], canVerifyResult: readable)
    }
    public func validate(_ action: ActionDefinition, context: ActionContext) throws {
        guard let operation = action.parameters["operation"].flatMap(MediaOperation.init(rawValue:)) else { throw ActionError("请选择多媒体操作。") }
        if [.playPause, .previous, .next].contains(operation), !KeyboardActionProvider.isAuthorized {
            throw ActionError("发送媒体控制需要在系统设置中允许智键使用辅助功能。")
        }
        if let step = action.parameters["step"], !(Double(step).map { $0.isFinite && (1...100).contains($0) } ?? false) {
            throw ActionError("音量步长须为 1–100。")
        }
    }
    public func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try validate(action, context: context); try Task.checkCancellation()
        let operation = MediaOperation(rawValue: action.parameters["operation"]!)!
        switch operation {
        case .playPause, .previous, .next:
            // Public IOKit hidsystem event constants: PLAY=16, NEXT=17, PREVIOUS=18;
            // AUX_CONTROL_BUTTONS=8. Route like hardware media keys, never a space key.
            let key = operation == .playPause ? 16 : operation == .next ? 17 : 18
            let events = [0xA, 0xB].compactMap { state in
                NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8,
                    data1: (key << 16) | (state << 8), data2: -1)?.cgEvent
            }
            guard events.count == 2 else { throw ActionError("无法创建媒体控制事件。") }
            events.forEach { $0.post(tap: .cghidEventTap) }
            return ActionResult("已发送系统媒体指令，目标由系统媒体路由决定。")
        case .mute:
            let device = try defaultDevice()
            var address = property(kAudioDevicePropertyMute)
            try ensureWritable(device, &address)
            var value: UInt32 = try readValue(device, &address, initial: UInt32(0))
            value = value == 0 ? 1 : 0
            try setValue(device, &address, value: &value)
            let actual: UInt32 = try readValue(device, &address, initial: UInt32(0))
            guard value == actual else { throw ActionError("输出设备未确认静音状态。") }
            return ActionResult(actual == 1 ? "输出已静音。" : "输出已取消静音。", verified: true)
        case .volumeUp, .volumeDown:
            let device = try defaultDevice()
            var address = property(kAudioDevicePropertyVolumeScalar)
            try ensureWritable(device, &address)
            let current: Float32 = try readValue(device, &address, initial: Float32(0))
            let step = Float(action.parameters["step"] ?? "5")! / 100
            var value = min(1, max(0, current + (operation == .volumeUp ? step : -step)))
            try setValue(device, &address, value: &value)
            let actual: Float32 = try readValue(device, &address, initial: Float32(0))
            guard abs(actual - value) < 0.025 else { throw ActionError("设备未确认音量变化。") }
            return ActionResult("音量 \(Int((actual * 100).rounded()))%", verified: true)
        }
    }
    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private func defaultDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return try readValue(AudioObjectID(kAudioObjectSystemObject), &address, initial: AudioObjectID(0))
    }
    private func ensureWritable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) throws {
        var writable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue else {
            throw ActionError("当前输出设备不支持此软件音量/静音操作。")
        }
    }
    private func readValue<T: Numeric>(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, initial: T) throws -> T {
        var value = initial; var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw ActionError("无法读取音频设备状态。") }
        return value
    }
    private func setValue<T: Numeric>(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, value: inout T) throws {
        let status = withUnsafeBytes(of: &value) { AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0.baseAddress!) }
        guard status == noErr else { throw ActionError("无法设置音频设备。") }
    }
}
