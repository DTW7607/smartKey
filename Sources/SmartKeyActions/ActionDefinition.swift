import Foundation

public enum GestureSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case singleClick, doubleClick, longPress
    public var id: String { rawValue }
    public var title: String {
        switch self { case .singleClick: return "单击"; case .doubleClick: return "双击"; case .longPress: return "长按" }
    }
}

public enum ActionNames {
    public static let maxUnits = 12
    public static func unitCount(_ name: String) -> Int {
        name.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }
    public static func truncated(_ name: String, maxUnits: Int = maxUnits) -> String {
        var units = 0
        var result = ""
        for character in name {
            let weight = isWide(character) ? 2 : 1
            if units + weight > maxUnits { break }
            result.append(character)
            units += weight
        }
        return result
    }
    public static func validate(_ name: String) throws {
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...maxUnits).contains(unitCount(name)),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ActionError("名称须为 1–12 个字符，中文占 2 个字符，不能包含换行或首尾空格。")
        }
    }
    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            switch value {
            case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF00...0xFFEF,
                 0x1F200...0x1F2FF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}

public struct ActionError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ActionDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var typeID: String
    public var version: Int
    public var name: String
    public var parameters: [String: String]
    public init(id: UUID = UUID(), typeID: String, name: String, parameters: [String: String] = [:], version: Int = 1) {
        self.id = id; self.typeID = typeID; self.name = name; self.parameters = parameters; self.version = version
    }
}

public struct ScriptRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var interpreter: String
    public var workingDirectory: String
    public var timeout: Double
    public var environment: [String: String]
    public init(id: UUID = UUID(), name: String, summary: String = "", interpreter: String = "/bin/zsh",
                workingDirectory: String = "", timeout: Double = 30, environment: [String: String] = [:]) {
        self.id = id; self.name = name; self.summary = summary; self.interpreter = interpreter
        self.workingDirectory = workingDirectory; self.timeout = timeout; self.environment = environment
    }
    public func validate() throws {
        try ActionNames.validate(name)
        guard ["/bin/zsh", "/bin/bash"].contains(interpreter) else { throw ActionError("首版支持 zsh 或 bash。") }
        guard timeout.isFinite, (1...3600).contains(timeout) else { throw ActionError("超时须为 1–3600 秒。") }
        guard workingDirectory.isEmpty || workingDirectory.hasPrefix("/") else { throw ActionError("工作目录须为绝对路径。") }
        for (key, value) in environment {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
                throw ActionError("环境变量名称或内容无效。")
            }
        }
    }
}

public struct ActionDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var actions: [ActionDefinition] = []
    public var bindings: [String: UUID] = [:]
    public var scripts: [ScriptRecord] = []
    public var paused = false
    public init() {}
    public var doubleClickEnabled: Bool { bindings[GestureSlot.doubleClick.rawValue] != nil }
    public func action(for slot: GestureSlot) -> ActionDefinition? {
        guard let id = bindings[slot.rawValue], var action = actions.first(where: { $0.id == id }) else { return nil }
        if action.typeID == "script", let script = script(for: action) { action.name = script.name }
        if action.typeID == "media", let operation = action.parameters["operation"].flatMap(MediaOperation.init(rawValue:)) {
            action.name = operation.title
        }
        return action
    }
    public func script(for action: ActionDefinition) -> ScriptRecord? {
        guard let id = action.parameters["scriptID"].flatMap(UUID.init(uuidString:)) else { return nil }
        return scripts.first { $0.id == id }
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ActionError("配置版本不受支持，已保留原文件。") }
        guard Set(actions.map(\.id)).count == actions.count, Set(scripts.map(\.id)).count == scripts.count else {
            throw ActionError("配置包含重复 ID。")
        }
        guard Set(scripts.map { $0.name.folding(options: [.caseInsensitive], locale: nil) }).count == scripts.count else {
            throw ActionError("脚本名称不能重复。")
        }
        for script in scripts { try script.validate() }
        for action in actions {
            try ActionNames.validate(action.name)
            if action.typeID == "script", script(for: action) == nil { throw ActionError("动作引用的脚本不存在。") }
        }
        for (key, id) in bindings {
            guard GestureSlot(rawValue: key) != nil, actions.contains(where: { $0.id == id }) else {
                throw ActionError("手势绑定引用无效。")
            }
        }
    }
}
