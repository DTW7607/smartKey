import Foundation
import Combine

@MainActor
public final class ActionStore: ObservableObject {
    @Published public private(set) var document: ActionDocument
    public let directory: URL
    public private(set) var recoveryMessage: String?
    public let isReadOnly: Bool
    private let file: URL
    private let backup: URL

    public init(directory: URL, inMemory: Bool = false) throws {
        self.directory = directory
        file = directory.appendingPathComponent("actions.json")
        backup = directory.appendingPathComponent("actions.previous.json")
        isReadOnly = inMemory
        if !inMemory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        if !inMemory, FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                // A newer schema must never be silently downgraded to an older backup.
                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = object["schemaVersion"] as? Int, version != 1 {
                    throw ActionError("配置由其他版本创建，当前版本不能修改。")
                }
                let next = try JSONDecoder().decode(ActionDocument.self, from: data)
                try next.validate(); document = next
            } catch let error as ActionError where error.message.contains("其他版本") { throw error }
            catch {
                let next = try JSONDecoder().decode(ActionDocument.self, from: Data(contentsOf: backup))
                try next.validate(); document = next
                recoveryMessage = "配置无法读取，正在使用上一有效版本。下一次保存会保留损坏文件副本。"
            }
        } else { document = ActionDocument() }
    }

    public func change(_ edit: (inout ActionDocument) throws -> Void) throws {
        guard !isReadOnly else { throw ActionError("配置未正常载入，当前只读。请检查配置文件后重启。") }
        var next = document
        try edit(&next); try next.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        if recoveryMessage != nil, FileManager.default.fileExists(atPath: file.path) {
            let damaged = directory.appendingPathComponent("actions.damaged-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: damaged)
        }
        try encoder.encode(document).write(to: backup, options: .atomic)
        try data.write(to: file, options: .atomic)
        document = next; recoveryMessage = nil
    }

    public func bind(_ action: ActionDefinition?, to slot: GestureSlot) throws {
        try change { next in
            if let oldID = next.bindings.removeValue(forKey: slot.rawValue), !next.bindings.values.contains(oldID) {
                next.actions.removeAll { $0.id == oldID }
            }
            if let action {
                next.actions.removeAll { $0.id == action.id }; next.actions.append(action)
                next.bindings[slot.rawValue] = action.id
            }
        }
    }

    public func saveScript(_ script: ScriptRecord) throws {
        try change { next in
            if let index = next.scripts.firstIndex(where: { $0.id == script.id }) {
                next.scripts[index] = script
            } else {
                next.scripts.append(script)
            }
            for index in next.actions.indices where next.actions[index].typeID == "script" && next.actions[index].parameters["scriptID"] == script.id.uuidString {
                next.actions[index].name = script.name
            }
        }
    }

    public func moveScripts(from offsets: IndexSet, to destination: Int) throws {
        try change { next in next.scripts.move(fromOffsets: offsets, toOffset: destination) }
    }

    public func references(to script: ScriptRecord) -> [GestureSlot] {
        GestureSlot.allCases.filter { document.action(for: $0)?.parameters["scriptID"] == script.id.uuidString }
    }

    public func removeScript(_ script: ScriptRecord, unbind: Bool) throws {
        guard unbind || references(to: script).isEmpty else { throw ActionError("该脚本仍被动作绑定引用。") }
        try change { next in
            let ids = Set(next.actions.filter { $0.typeID == "script" && $0.parameters["scriptID"] == script.id.uuidString }.map(\.id))
            next.bindings = next.bindings.filter { !ids.contains($0.value) }
            next.actions.removeAll { ids.contains($0.id) }; next.scripts.removeAll { $0.id == script.id }
        }
    }
}
