import AppKit
import SwiftUI
import Testing
import SmartKeyActions
@testable import smartKeyPopup

@MainActor
private final class RecordingShortcutProvider: ActionProvider {
    let typeID = "shortcut"
    var sources: [ExecutionSource] = []
    func validate(_ action: ActionDefinition, context: ActionContext) throws { _ = try ShortcutParameters(action: action) }
    func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        sources.append(context.source)
        return ActionResult("模拟完成", verified: true, exitCode: 0)
    }
}

@MainActor
private final class DelayedShortcutProvider: ActionProvider {
    let typeID = "shortcut"
    let delayMs: UInt64
    init(delayMs: UInt64) { self.delayMs = delayMs }
    func validate(_ action: ActionDefinition, context: ActionContext) throws { _ = try ShortcutParameters(action: action) }
    func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try await Task.sleep(for: .milliseconds(delayMs))
        return ActionResult("模拟完成", verified: true, exitCode: 0)
    }
}

@Suite @MainActor
struct ActionIntegrationTests {
    private func fixture() throws -> (URL, RuntimeConfiguration, ActionCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("smartKey.conf")
        try "# 用户配置\ndoubleClickEnabled = 0 # 自动\nbubbleEndY = 24\ncustomValue = keep\n".write(to: file, atomically: true, encoding: .utf8)
        let configuration = RuntimeConfiguration.load(url: file)
        return (directory, configuration, try ActionCoordinator(configuration: configuration, directory: directory,
                                                               permissions: PermissionsModel(check: { _ in true })))
    }

    @Test func bindingOwnsDoubleClickAndPreservesUnrelatedConfiguration() throws {
        let (directory, configuration, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.bind(ActionDefinition(typeID: "media", name: "下一首", parameters: ["operation": "next"]), to: .doubleClick)
        #expect(configuration.doubleClickEnabled == 1)
        var contents = try String(contentsOf: directory.appendingPathComponent("smartKey.conf"), encoding: .utf8)
        #expect(contents.contains("bubbleEndY = 24")); #expect(contents.contains("customValue = keep")); #expect(contents.contains("# 自动"))
        try configuration.write(["doubleClickEnabled": 0])
        coordinator.synchronizeDoubleClick()
        #expect(configuration.doubleClickEnabled == 1)
        coordinator.bind(nil, to: .doubleClick)
        #expect(configuration.doubleClickEnabled == 0)
        contents = try String(contentsOf: directory.appendingPathComponent("smartKey.conf"), encoding: .utf8)
        #expect(contents.contains("customValue = keep"))
    }

    @Test func shortcutProviderIsRegisteredAndAllGesturesAndTestUseIt() async throws {
        for slot in GestureSlot.allCases {
            let (directory, configuration, coordinator) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let action = ActionDefinition(typeID: "shortcut", name: "快捷指令",
                parameters: ["shortcutID": UUID().uuidString, "shortcutName": "长名称快捷指令", "timeout": "300"])
            #expect(try coordinator.dispatcher.registry.provider(for: action) is ShortcutActionProvider)
            let provider = RecordingShortcutProvider()
            coordinator.dispatcher.registry.register(provider)
            coordinator.bind(action, to: slot)
            #expect(configuration.doubleClickEnabled == (slot == .doubleClick ? 1 : 0))
            coordinator.beginSession()
            coordinator.runPhysical(slot)
            coordinator.endSession()
            coordinator.test(action)
            for _ in 0..<100 {
                if coordinator.dispatcher.runningTasks.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(provider.sources.count == 2)
            #expect(provider.sources.contains { if case .physical = $0 { return true }; return false })
            #expect(provider.sources.contains { if case .test = $0 { return true }; return false })
            #expect(coordinator.dispatcher.executions.allSatisfy { $0.state == .succeeded })
            #expect(try ActionStore(directory: directory).document.action(for: slot)?.parameters == action.parameters)
        }
    }

    @Test func physicalFeedbackFiresOnceAtStartAfterSlowShortcutFinishes() async throws {
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = ActionDefinition(typeID: "shortcut", name: "快捷指令",
            parameters: ["shortcutID": UUID().uuidString, "timeout": "300"])
        coordinator.dispatcher.registry.register(DelayedShortcutProvider(delayMs: 40))
        coordinator.bind(action, to: .longPress)
        var feedback: [ExecutionState] = []
        coordinator.onFeedback = { feedback.append($0.state) }
        coordinator.beginSession()
        coordinator.runPhysical(.longPress)
        coordinator.endSession()
        for _ in 0..<100 {
            if coordinator.dispatcher.runningTasks.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(feedback == [.running])
        #expect(coordinator.dispatcher.executions.first?.state == .succeeded)
        #expect(coordinator.lastExecution?.state == .succeeded)
    }

    @Test func packageImportPreservesMetadataAndAssignsNewIdentity() throws {
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ScriptRecord(name: "便捷操作", summary: "包说明", interpreter: "/bin/bash", timeout: 12)
        let package = ScriptPackage(script: ScriptPackageMetadata(record: record), content: "printf ok\n")
        let source = directory.appendingPathComponent("source.smartkeyscript")
        try JSONEncoder().encode(package).write(to: source)
        coordinator.importScript(source)
        let imported = try #require(coordinator.store.document.scripts.first)
        #expect(imported.id != record.id); #expect(imported.name == record.name); #expect(imported.summary == record.summary)
        #expect(imported.interpreter == "/bin/bash"); #expect(imported.timeout == 12)
        coordinator.bind(ActionDefinition(typeID: "script", name: imported.name, parameters: ["scriptID": imported.id.uuidString]), to: .doubleClick)
        coordinator.delete(imported)
        #expect(coordinator.store.document.bindings.isEmpty)
        #expect(!coordinator.store.document.doubleClickEnabled)
    }

    @Test func configurationWriteFailureDoesNotPretendToBeSaved() throws {
        let configuration = RuntimeConfiguration(values: RuntimeSettings())
        #expect(throws: (any Error).self) { try configuration.write(["doubleClickEnabled": 1]) }
        #expect(configuration.doubleClickEnabled == 0)
    }

    @Test func sessionUsesCapturedBindingAndNoActionIsSilent() throws {
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.beginSession(); coordinator.runPhysical(.singleClick)
        #expect(coordinator.dispatcher.executions.isEmpty)
        coordinator.endSession()
        coordinator.bind(ActionDefinition(typeID: "unavailable", name: "旧动作"), to: .singleClick)
        coordinator.beginSession()
        coordinator.bind(ActionDefinition(typeID: "unavailable", name: "新动作"), to: .singleClick)
        coordinator.runPhysical(.singleClick)
        #expect(coordinator.dispatcher.executions.first?.action.name == "旧动作")
        coordinator.endSession()
    }

    @Test func listRenameSurvivesPendingDetailsSaveAndReopen() throws {
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(coordinator.createScript())
        coordinator.bind(ActionDefinition(typeID: "script", name: original.name,
            parameters: ["scriptID": original.id.uuidString]), to: .singleClick)
        var editor = ScriptDraft(script: original)
        editor.script.summary = "尚未自动保存的说明"
        editor.script.timeout = 42
        var renamed = original
        renamed.name = "新名称"
        coordinator.saveScript(renamed)

        // A pending autosave or onDisappear still holds the old details draft.
        editor.synchronizeName(with: try #require(coordinator.store.document.scripts.first))
        #expect(editor.script.name == "新名称")
        #expect(editor.script.summary == "尚未自动保存的说明")
        #expect(editor.script.timeout == 42)
        try coordinator.store.saveScript(editor.script)
        editor.didSave(editor.script)

        let reopened = try ActionStore(directory: directory)
        #expect(reopened.document.scripts.first?.name == "新名称")
        #expect(reopened.document.scripts.first?.summary == "尚未自动保存的说明")
        #expect(reopened.document.action(for: .singleClick)?.name == "新名称")
    }

    @Test func cachedInvalidDraftAcceptsListRenameWithoutLosingEdits() throws {
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try #require(coordinator.createScript())
        var editor = ScriptDraft(script: original)
        editor.script.name = "未保存名称"
        editor.script.summary = "保留说明"
        editor.environmentText = "invalid environment"
        coordinator.scriptDrafts[original.id] = editor
        var renamed = original
        renamed.name = "列表改名"
        coordinator.saveScript(renamed)

        var restored = try #require(coordinator.scriptDrafts[original.id])
        restored.synchronizeName(with: try #require(coordinator.store.document.scripts.first))
        #expect(restored.script.name == "列表改名")
        #expect(restored.script.summary == "保留说明")
        #expect(restored.environmentText == "invalid environment")
    }

    @Test func detailsRenameRemainsEditableAcrossAutosaves() {
        let original = ScriptRecord(name: "原名称")
        var editor = ScriptDraft(script: original)
        editor.script.name = "详情改名"
        editor.synchronizeName(with: original)
        #expect(editor.script.name == "详情改名")
        let saved = editor.script
        editor.didSave(saved)
        editor.script.name = "再次改名"
        editor.synchronizeName(with: saved)
        #expect(editor.script.name == "再次改名")
    }

    @Test func renderSettingsPages() throws {
        _ = NSApplication.shared
        let (directory, _, coordinator) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.deviceStatus = "已启用 · 内置 3.5 mm 智键"
        let script = try #require(coordinator.createScript())
        coordinator.bind(ActionDefinition(typeID: "keyboard", name: "保存文档", parameters: ["keyCode": "1", "modifiers": "1048576", "display": "⌘S"]), to: .singleClick)
        coordinator.bind(ActionDefinition(typeID: "script", name: script.name, parameters: ["scriptID": script.id.uuidString]), to: .longPress)
        let pages: [(String, AnyView)] = [
            ("bindings", AnyView(BindingsSettingsView(coordinator: coordinator))),
            ("general", AnyView(GeneralSettingsView(coordinator: coordinator))),
            ("scripts", AnyView(ScriptDetailsView(coordinator: coordinator, original: script)))
        ]
        for (name, page) in pages {
            for dark in [false, true] {
                let view = NSHostingView(rootView: page.frame(width: 660, height: 620).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 660, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view; window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/smartKey-settings-\(name)\(dark ? "-dark" : "").png"))
                #expect(view.bounds.width == 660); #expect(view.bounds.height == 620)
                window.orderOut(nil)
            }
        }
    }
}
