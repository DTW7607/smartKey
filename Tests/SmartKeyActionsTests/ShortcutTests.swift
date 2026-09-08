import Foundation
import Testing
@testable import SmartKeyActions

private actor FakeShortcutRunner: ShortcutCommandRunning {
    struct Call: Sendable {
        let arguments: [String]
        let timeout: Double
        let waitingOnly: Bool
    }
    var result = ActionResult("", exitCode: 0)
    var calls: [Call] = []
    var delay = false
    var failure: ActionRunError?

    func configure(_ result: ActionResult = ActionResult("", exitCode: 0), delay: Bool = false, failure: ActionRunError? = nil) {
        self.result = result; self.delay = delay; self.failure = failure
    }
    func run(arguments: [String], timeout: Double, waitingOnly: Bool) async throws -> ActionResult {
        calls.append(Call(arguments: arguments, timeout: timeout, waitingOnly: waitingOnly))
        if delay { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        return result
    }
}

@Suite @MainActor
struct ShortcutTests {
    private let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    private func action(name: String = "专注", timeout: String = "300") -> ActionDefinition {
        ActionDefinition(typeID: "shortcut", name: name,
                         parameters: ["shortcutID": id.uuidString, "shortcutName": "专注 (工作)", "timeout": timeout])
    }
    private func dispatcher(_ runner: FakeShortcutRunner) -> ActionDispatcher {
        let registry = ActionRegistry()
        registry.register(ShortcutActionProvider(runner: runner))
        return ActionDispatcher(registry: registry)
    }
    private func finish(_ execution: ActionExecution) async throws {
        for _ in 0..<500 {
            if execution.state != .running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("快捷指令未在测试期限内结束")
        execution.cancel()
    }

    @Test func listParsesNamesAndStableIdentifiers() throws {
        let second = UUID()
        let third = UUID()
        let entries = try ShortcutCatalog.parse("中文 (工作) $(touch /tmp/no) (\(id))\n同名 (\(second))\n同名 (\(third))\n")
        #expect(entries.count == 3)
        #expect(entries.first { $0.id == id }?.name == "中文 (工作) $(touch /tmp/no)")
        #expect(entries.filter { $0.name == "同名" }.count == 2)
        #expect(try ShortcutCatalog.parse("").isEmpty)
        #expect(try ShortcutCatalog.parse("多行\n名称 (\(id))").first?.name == "多行\n名称")
        #expect(try ShortcutCatalog.parse("名称 (\(id))\r\n").first?.id == id)
    }

    @Test func malformedOrTruncatedListIsRejected() {
        for output in ["名称 (not-an-id)\n", "名称 (\(id))\n[输出已截断]", "名称 (\(id))\n重复 (\(id))\n"] {
            #expect(throws: ActionError.self) { try ShortcutCatalog.parse(output) }
        }
    }

    @Test func refreshRetainsCacheOnFailureAndTracksRenameAndDeletion() async throws {
        let runner = FakeShortcutRunner()
        let catalog = ShortcutCatalog(runner: runner)
        await runner.configure(ActionResult("", exitCode: 0, stdout: "原名 (\(id))\n"))
        await catalog.refresh()
        #expect(catalog.hasLoaded && !catalog.isLoading && catalog.error == nil)
        #expect(catalog.shortcuts.first?.name == "原名")
        await runner.configure(ActionResult("", exitCode: 1, stderr: "permission denied"))
        await catalog.refresh()
        #expect(catalog.error?.contains("permission denied") == true)
        #expect(catalog.shortcuts.first?.id == id)
        await runner.configure(ActionResult("", exitCode: 0, stdout: "新名 (\(id))\n"))
        await catalog.refresh()
        #expect(catalog.shortcuts.first?.name == "新名")
        #expect(catalog.error == nil)
        await runner.configure()
        await catalog.refresh()
        #expect(catalog.shortcuts.isEmpty)
        let calls = await runner.calls
        #expect(calls.allSatisfy { $0.arguments == ["list", "--show-identifiers"] && $0.timeout == 15 })
    }

    @Test func validationRejectsBadIDAndTimeoutBeforeLaunching() async throws {
        let runner = FakeShortcutRunner()
        let dispatcher = dispatcher(runner)
        var invalidID = action()
        invalidID.parameters["shortcutID"] = "--help; touch /tmp/no"
        for invalid in [invalidID, action(timeout: "nan"), action(timeout: "0"), action(timeout: "3601"), action(timeout: "")] {
            let execution = try #require(dispatcher.run(invalid, context: ActionContext(source: .test)))
            try await finish(execution)
            #expect(execution.state == .failed)
        }
        #expect(await runner.calls.isEmpty)
        var defaultTimeout = action()
        defaultTimeout.parameters.removeValue(forKey: "timeout")
        #expect(try ShortcutParameters(action: defaultTimeout).timeout == 300)
    }

    @Test func executesByIDAndReportsSystemResult() async throws {
        let runner = FakeShortcutRunner()
        await runner.configure(ActionResult("", exitCode: 0, stdout: "完成输出"))
        let dispatcher = dispatcher(runner)
        let execution = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        #expect(dispatcher.runningTasks.contains { $0 === execution })
        try await finish(execution)
        #expect(execution.state == .succeeded)
        #expect(execution.result?.stdout == "完成输出")
        #expect(dispatcher.runningTasks.isEmpty)
        let call = try #require(await runner.calls.first)
        #expect(call.arguments == ["run", id.uuidString])
        #expect(call.timeout == 300 && call.waitingOnly)

        await runner.configure(ActionResult("", exitCode: 1, stderr: "Shortcut not found"))
        let missing = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        try await finish(missing)
        #expect(missing.state == .failed)
        #expect(missing.result?.message.contains("Shortcut not found") == true)
        #expect(missing.result?.verified == false)
    }

    @Test func busyRejectsRepeatAndCancelReleasesSlot() async throws {
        let runner = FakeShortcutRunner()
        await runner.configure(delay: true)
        let dispatcher = dispatcher(runner)
        let first = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        for _ in 0..<100 {
            if await !runner.calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        try await finish(second)
        #expect(second.state == .failed)
        #expect(second.result?.message.contains("已有快捷指令运行中") == true)
        #expect(await runner.calls.count == 1)
        dispatcher.cancelAll()
        try await finish(first)
        #expect(first.state == .cancelled)
        #expect(first.stateTitle == "已停止等待")
        await runner.configure()
        let next = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        try await finish(next)
        #expect(next.state == .succeeded)
    }

    @Test func timeoutPreservesWaitingSemanticsAndOutput() async throws {
        let runner = FakeShortcutRunner()
        await runner.configure(failure: ActionRunError(state: .timedOut,
            result: ActionResult("已停止等待，快捷指令可能仍在运行。", stdout: "partial")))
        let dispatcher = dispatcher(runner)
        let execution = try #require(dispatcher.run(action(), context: ActionContext(source: .test)))
        try await finish(execution)
        #expect(execution.state == .timedOut)
        #expect(execution.result?.stdout == "partial")
        #expect(execution.result?.verified == false)
    }

    @Test func openingUsesIDWithoutRunningShortcut() async throws {
        let runner = FakeShortcutRunner()
        try await ShortcutCatalog(runner: runner).open(id)
        #expect(await runner.calls.first?.arguments == ["view", id.uuidString])
    }

    @Test func bindingsRoundTripWithoutShortcutLibraryAndPreserveUnknownVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ActionStore(directory: directory)
        for slot in GestureSlot.allCases { try store.bind(action(), to: slot) }
        let reopened = try ActionStore(directory: directory)
        #expect(reopened.document.schemaVersion == 1)
        for slot in GestureSlot.allCases {
            #expect(reopened.document.action(for: slot)?.parameters["shortcutID"] == id.uuidString)
        }
        var future = action()
        future.version = 2
        try reopened.bind(future, to: .singleClick)
        let registry = ActionRegistry()
        registry.register(ShortcutActionProvider(runner: FakeShortcutRunner()))
        #expect(throws: ActionError.self) { try registry.provider(for: future) }
        #expect(try ActionStore(directory: directory).document.action(for: .singleClick)?.version == 2)
    }

    @Test func managedProcessKeepsArgumentsLiteral() async throws {
        let argument = "空格 ' \" $(echo injected); & (内容)"
        let result = try await ManagedProcess().run {
            ManagedCommand(executable: "/usr/bin/printf", arguments: ["%s", argument], timeout: 5, label: "测试")
        }
        #expect(result.exitCode == 0)
        #expect(result.stdout == argument)
    }

    @Test func managedProcessTimeoutAndCancellationDoNotClaimShortcutStopped() async throws {
        let timedJob = ManagedProcess()
        do {
            _ = try await timedJob.run {
                ManagedCommand(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1,
                               label: "快捷指令", stopsWaitingOnly: true)
            }
            Issue.record("应超时")
        } catch let error as ActionRunError {
            #expect(error.state == .timedOut)
            #expect(error.result.message.contains("已停止等待"))
            #expect(error.result.message.contains("可能仍在系统中运行"))
            #expect(!error.result.verified)
        }
        let cancelled = ManagedProcess()
        cancelled.stop(.cancelled)
        do {
            _ = try await cancelled.run {
                ManagedCommand(executable: "/bin/sleep", arguments: ["10"], timeout: 5,
                               label: "快捷指令", stopsWaitingOnly: true)
            }
            Issue.record("启动前取消应阻止执行")
        } catch let error as ActionRunError {
            #expect(error.state == .cancelled)
            #expect(error.result.message.contains("已停止等待"))
            #expect(error.result.exitCode == nil)
        }
    }
}
