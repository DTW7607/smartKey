import Foundation
import Testing
@testable import SmartKeyActions

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartKey-actions-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

@MainActor
private func waitForCompletion(_ execution: ActionExecution) async {
    for _ in 0..<200 {
        if execution.state != .running { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
private final class FakeProvider: ActionProvider {
    let typeID = "fake"
    var validationError: Error?
    var executionError: Error?
    var result = ActionResult("完成", verified: true)
    private(set) var validationCount = 0
    private(set) var executionCount = 0

    func validate(_ action: ActionDefinition, context: ActionContext) throws {
        validationCount += 1
        if let validationError { throw validationError }
    }

    func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        executionCount += 1
        if let executionError { throw executionError }
        return result
    }
}

@MainActor
@Suite
struct ActionCoreTests {
    @Test
    func actionNamesCountUnicodeCharactersAndRejectInvalidNames() throws {
        try ActionNames.validate("中文😀确认状态好")

        #expect(throws: ActionError.self) {
            try ActionNames.validate("一二三四五六七八九")
        }
        #expect(throws: ActionError.self) {
            try ActionNames.validate(" 名")
        }
        #expect(throws: ActionError.self) {
            try ActionNames.validate("好\n")
        }
        #expect(throws: ActionError.self) {
            try ActionNames.validate("")
        }
    }

    @Test
    func emptyBindingKeepsDoubleClickDerivedFromBinding() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let action = ActionDefinition(typeID: "fake", name: "测试")

        #expect(store.document.bindings.isEmpty)
        #expect(!store.document.doubleClickEnabled)

        try store.bind(action, to: .doubleClick)
        #expect(store.document.doubleClickEnabled)
        try store.bind(nil, to: .doubleClick)
        #expect(store.document.bindings.isEmpty)
        #expect(!store.document.doubleClickEnabled)
        #expect(store.document.actions.isEmpty)
    }

    @Test
    func savingAndReopeningPreservesDocument() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let script = ScriptRecord(id: UUID(), name: "脚本")
        try store.saveScript(script)
        let action = ActionDefinition(
            typeID: "script",
            name: "旧名",
            parameters: ["scriptID": script.id.uuidString]
        )
        try store.bind(action, to: .singleClick)
        try store.change { $0.paused = true }

        let reopened = try ActionStore(directory: directory)
        #expect(reopened.document == store.document)
        #expect(reopened.document.paused)
        #expect(reopened.document.doubleClickEnabled == false)
        #expect(reopened.document.action(for: .singleClick)?.name == "脚本")
    }

    @Test
    func referencedScriptRequiresUnbindBeforeRemoval() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let script = ScriptRecord(id: UUID(), name: "脚本")
        try store.saveScript(script)
        try store.bind(
            ActionDefinition(typeID: "script", name: "脚本", parameters: ["scriptID": script.id.uuidString]),
            to: .singleClick
        )

        #expect(store.references(to: script) == [.singleClick])
        #expect(throws: ActionError.self) {
            try store.removeScript(script, unbind: false)
        }
        #expect(store.document.scripts.contains(script))
        #expect(store.document.bindings[GestureSlot.singleClick.rawValue] != nil)

        try store.removeScript(script, unbind: true)
        #expect(store.document.scripts.isEmpty)
        #expect(store.document.actions.isEmpty)
        #expect(store.document.bindings.isEmpty)
    }

    @Test
    func renamingScriptSynchronizesBoundActionName() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let scriptID = UUID()
        let original = ScriptRecord(id: scriptID, name: "原名")
        try store.saveScript(original)
        try store.bind(
            ActionDefinition(typeID: "script", name: "原名", parameters: ["scriptID": scriptID.uuidString]),
            to: .singleClick
        )

        let renamed = ScriptRecord(id: scriptID, name: "新名")
        try store.saveScript(renamed)
        #expect(store.document.actions.first?.name == "新名")
        #expect(store.document.action(for: .singleClick)?.name == "新名")
    }

    @Test
    func damagedConfigRecoversFromBackupAndNewSchemaIsNeverDowngraded() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let action = ActionDefinition(typeID: "future", name: "保留")
        try store.bind(action, to: .singleClick)
        try store.change { $0.paused = true }

        let file = directory.appendingPathComponent("actions.json")
        let backup = directory.appendingPathComponent("actions.previous.json")
        let backupDocument = try JSONDecoder().decode(ActionDocument.self, from: Data(contentsOf: backup))
        try Data("{\"schemaVersion\":1,\"actions\":[".utf8).write(to: file)

        let recovered = try ActionStore(directory: directory)
        #expect(recovered.document == backupDocument)
        #expect(recovered.recoveryMessage != nil)
        try recovered.change { $0.paused = true }
        #expect(recovered.recoveryMessage == nil)
        let damaged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("actions.damaged-") }
        #expect(damaged.count == 1)

        let newerDirectory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(newerDirectory) }
        let newerStore = try ActionStore(directory: newerDirectory)
        try newerStore.bind(ActionDefinition(typeID: "future", name: "保留"), to: .singleClick)
        let newerFile = newerDirectory.appendingPathComponent("actions.json")
        let newerBackup = newerDirectory.appendingPathComponent("actions.previous.json")
        let backupBeforeNewerSchema = try Data(contentsOf: newerBackup)
        let newerData = Data("{\"schemaVersion\":2}".utf8)
        try newerData.write(to: newerFile)

        var didRejectNewerSchema = false
        do {
            _ = try ActionStore(directory: newerDirectory)
        } catch let error as ActionError {
            didRejectNewerSchema = true
            #expect(error.message.contains("其他版本"))
        } catch {
            didRejectNewerSchema = true
            Issue.record("新 schema 应抛出 ActionError，实际错误：\(error)")
        }
        #expect(didRejectNewerSchema)
        let currentNewerData = try Data(contentsOf: newerFile)
        let currentBackupData = try Data(contentsOf: newerBackup)
        #expect(currentNewerData == newerData)
        #expect(currentBackupData == backupBeforeNewerSchema)
    }

    @Test
    func unknownProviderIsRetainedButExecutionFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = try ActionStore(directory: directory)
        let action = ActionDefinition(typeID: "future.provider", name: "未知")
        try store.bind(action, to: .singleClick)

        let reopened = try ActionStore(directory: directory)
        let retained = try #require(reopened.document.action(for: .singleClick))
        let dispatcher = ActionDispatcher(registry: ActionRegistry())
        let execution = try #require(dispatcher.run(retained, context: ActionContext(source: .test)))
        await waitForCompletion(execution)

        #expect(execution.state == .failed)
        #expect(execution.result?.message.contains("不支持") == true)
    }

    @Test
    func physicalCooldownRejectsRapidRunsButNoneDoesNotConsumeIt() async throws {
        let provider = FakeProvider()
        let registry = ActionRegistry()
        registry.register(provider)
        var uptime: TimeInterval = 100
        let dispatcher = ActionDispatcher(registry: registry, now: { uptime })
        dispatcher.cooldown = 1
        let action = ActionDefinition(typeID: provider.typeID, name: "测试")
        let context = ActionContext(source: .physical)

        #expect(dispatcher.run(nil, context: context) == nil)
        let first = try #require(dispatcher.run(action, context: context))
        #expect(dispatcher.run(action, context: context) == nil)
        await waitForCompletion(first)

        uptime += 1
        let second = try #require(dispatcher.run(action, context: context))
        await waitForCompletion(second)
        #expect(first.state == .succeeded)
        #expect(second.state == .succeeded)
        #expect(provider.executionCount == 2)
    }

    @Test
    func providerExecutionErrorProducesFailedStatus() async throws {
        let provider = FakeProvider()
        provider.executionError = ActionError("模拟执行错误")
        let registry = ActionRegistry()
        registry.register(provider)
        let dispatcher = ActionDispatcher(registry: registry)
        let action = ActionDefinition(typeID: provider.typeID, name: "测试")
        let execution = try #require(dispatcher.run(action, context: ActionContext(source: .test)))
        await waitForCompletion(execution)

        #expect(execution.state == .failed)
        #expect(execution.result?.message == "模拟执行错误")
        #expect(provider.validationCount == 1)
        #expect(provider.executionCount == 1)
    }
}
