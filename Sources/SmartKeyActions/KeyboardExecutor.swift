import AppKit
import ApplicationServices

@MainActor
public final class KeyboardActionProvider: ActionProvider {
    public let typeID = "keyboard"
    public init() {}
    public func capabilities(for action: ActionDefinition) -> ActionCapabilities { ActionCapabilities(permissions: ["辅助功能"]) }
    public static var isAuthorized: Bool { AXIsProcessTrusted() }
    public static func requestAuthorization() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    public func validate(_ action: ActionDefinition, context: ActionContext) throws {
        guard let code = action.parameters["keyCode"].flatMap(UInt16.init), code <= 127,
              let flags = action.parameters["modifiers"].flatMap(UInt64.init), flags & ~Self.allowedFlags == 0 else {
            throw ActionError("请录制一个按键或组合键。")
        }
        guard Self.isAuthorized else { throw ActionError("请在系统设置 → 隐私与安全性 → 辅助功能中允许智键控制键盘。") }
    }
    public static var allowedFlags: UInt64 { CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue }
    public func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try validate(action, context: context); try Task.checkCancellation()
        if let pid = context.targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            throw ActionError("目标应用已变化，本次按键已取消。")
        }
        let code = UInt16(action.parameters["keyCode"]!)!
        let flags = CGEventFlags(rawValue: UInt64(action.parameters["modifiers"]!)!)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw ActionError("无法创建键盘事件。") }
        // No asynchronous suspension between down and up; do not synthesize
        // modifier key-up events that could release a physically held modifier.
        let physical = CGEventSource.flagsState(.combinedSessionState).intersection(CGEventFlags(rawValue: Self.allowedFlags))
        down.flags = flags.union(physical); up.flags = physical
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return ActionResult("已向当前应用发送组合键。")
    }
}
