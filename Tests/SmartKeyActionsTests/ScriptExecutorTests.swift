import Darwin
import Foundation
import Testing
@testable import SmartKeyActions

private func makeScriptTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("smartKey-script-executor-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func removeScriptTestDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func writeScript(_ content: String, to url: URL) throws {
    try Data(content.utf8).write(to: url, options: [.atomic])
}

private func readPID(at url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value > 1 else { return nil }
    return pid_t(value)
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func forceKillProcessGroup(_ pid: pid_t?) {
    guard let pid, pid > 1 else { return }
    _ = kill(-pid, SIGKILL)
}

@MainActor
private func waitForTerminal(_ execution: ActionExecution, timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while execution.state == .running && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return execution.state != .running
}

@MainActor
private func waitForFile(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

@MainActor
private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processIsAlive(pid) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return !processIsAlive(pid)
}

@MainActor
private func makeScript(
    in directory: URL,
    content: String,
    name: String,
    interpreter: String = "/bin/zsh",
    workingDirectory: URL? = nil,
    timeout: Double = 5,
    environment: [String: String] = [:]
) throws -> (record: ScriptRecord, url: URL) {
    let id = UUID()
    let url = directory.appendingPathComponent("script-\(id.uuidString).sh")
    try writeScript(content, to: url)
    let record = ScriptRecord(
        id: id,
        name: name,
        interpreter: interpreter,
        workingDirectory: workingDirectory?.path ?? "",
        timeout: timeout,
        environment: environment
    )
    return (record, url)
}

@MainActor
private func runScript(
    _ script: (record: ScriptRecord, url: URL),
    dispatcher: ActionDispatcher,
    source: ExecutionSource = .test
) throws -> ActionExecution {
    let action = ActionDefinition(typeID: "script", name: script.record.name)
    let context = ActionContext(source: source, script: script.record, scriptURL: script.url)
    guard let execution = dispatcher.run(action, context: context) else {
        throw ActionError("脚本未创建执行记录。")
    }
    return execution
}

@MainActor
@Suite
struct ScriptExecutorTests {
    @Test
    func succeedsWithStdoutStderrAndExitCode() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let script = try makeScript(
            in: directory,
            content: "printf '标准输出'; printf '标准错误' >&2; exit 0\n",
            name: "成功",
            interpreter: "/bin/bash"
        )
        let provider = ScriptActionProvider()
        let registry = ActionRegistry()
        registry.register(provider)
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForTerminal(execution))

        #expect(execution.state == .succeeded)
        #expect(execution.result?.verified == true)
        #expect(execution.result?.exitCode == 0)
        #expect(execution.result?.stdout == "标准输出")
        #expect(execution.result?.stderr == "标准错误")
        #expect(execution.result?.message == "脚本退出码：0")
    }

    @Test
    func nonzeroExitBecomesFailedWithCapturedOutput() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let script = try makeScript(
            in: directory,
            content: "printf '失败输出'; printf '失败错误' >&2; exit 7\n",
            name: "失败"
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForTerminal(execution))

        #expect(execution.state == .failed)
        #expect(execution.result?.exitCode == 7)
        #expect(execution.result?.stdout == "失败输出")
        #expect(execution.result?.stderr == "失败错误")
        #expect(execution.result?.message == "脚本退出码：7")
    }

    @Test
    func timeoutUsesMinimumValidatedTimeoutAndLeavesNoChild() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let groupFile = directory.appendingPathComponent("group.pid")
        let script = try makeScript(
            in: directory,
            content: "printf '%s' \"$$\" > \"$GROUP_FILE\"; sleep 5\n",
            name: "超时",
            timeout: 1,
            environment: ["GROUP_FILE": groupFile.path]
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForFile(groupFile))
        let groupPID = readPID(at: groupFile)
        #expect(await waitForTerminal(execution, timeout: 8))
        defer { forceKillProcessGroup(groupPID) }

        #expect(execution.state == .timedOut)
        #expect(execution.result?.message == "超过 1 秒，已停止任务。")
        #expect(execution.result?.exitCode != nil)
        if let groupPID {
            #expect(await waitForProcessExit(groupPID))
        }
    }

    @Test
    func cancellationStopsScriptAndReportsCancelled() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let groupFile = directory.appendingPathComponent("group.pid")
        let script = try makeScript(
            in: directory,
            content: "printf '%s' \"$$\" > \"$GROUP_FILE\"; while :; do sleep 1; done\n",
            name: "取消",
            environment: ["GROUP_FILE": groupFile.path]
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForFile(groupFile))
        let groupPID = readPID(at: groupFile)
        execution.cancel()
        #expect(await waitForTerminal(execution, timeout: 8))
        defer { forceKillProcessGroup(groupPID) }

        #expect(execution.state == .cancelled)
        #expect(execution.result?.message == "任务已停止。")
        if let groupPID {
            #expect(await waitForProcessExit(groupPID))
        }
    }

    @Test
    func secondScriptRunFailsBusyUntilFirstCompletes() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let startedFile = directory.appendingPathComponent("started")
        let firstScript = try makeScript(
            in: directory,
            // Stay busy until cancelled; a fixed sleep can finish while other
            // main-actor tests render UI on a slower CI runner.
            content: "printf started > \"$STARTED_FILE\"; while :; do sleep 1; done\n",
            name: "第一",
            timeout: 30,
            environment: ["STARTED_FILE": startedFile.path]
        )
        let secondScript = try makeScript(in: directory, content: "printf second\n", name: "第二")
        let provider = ScriptActionProvider()
        let registry = ActionRegistry()
        registry.register(provider)
        let dispatcher = ActionDispatcher(registry: registry)
        let first = try runScript(firstScript, dispatcher: dispatcher)
        defer { first.cancel() }
        try #require(await waitForFile(startedFile))
        #expect(dispatcher.runningScript === first)

        let second = try runScript(secondScript, dispatcher: dispatcher)
        #expect(await waitForTerminal(second))
        #expect(second.state == .failed)
        #expect(second.result?.message.contains("已有脚本运行中") == true)

        first.cancel()
        #expect(await waitForTerminal(first, timeout: 8))
        #expect(first.state == .cancelled)

        let afterCancellation = try runScript(secondScript, dispatcher: dispatcher)
        #expect(await waitForTerminal(afterCancellation))
        #expect(afterCancellation.state == .succeeded)
        #expect(afterCancellation.result?.stdout == "second")
    }

    @Test
    func externalAtomicSaveIsUsedByTheNextRun() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let script = try makeScript(in: directory, content: "printf first\n", name: "保存")
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let dispatcher = ActionDispatcher(registry: registry)

        let first = try runScript(script, dispatcher: dispatcher)
        #expect(await waitForTerminal(first))
        #expect(first.result?.stdout == "first")

        try writeScript("printf second\n", to: script.url)
        let second = try runScript(script, dispatcher: dispatcher)
        #expect(await waitForTerminal(second))
        #expect(second.result?.stdout == "second")
    }

    @Test
    func runningExecutionKeepsItsOriginalSourceSnapshot() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let startedFile = directory.appendingPathComponent("started")
        let script = try makeScript(
            in: directory,
            content: "printf started > \"$STARTED_FILE\"; sleep 1; printf old\n",
            name: "快照",
            environment: ["STARTED_FILE": startedFile.path]
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let dispatcher = ActionDispatcher(registry: registry)
        let execution = try runScript(script, dispatcher: dispatcher)
        #expect(await waitForFile(startedFile))
        try writeScript("printf new\n", to: script.url)
        #expect(await waitForTerminal(execution))

        #expect(execution.state == .succeeded)
        #expect(execution.result?.stdout == "old")
    }

    @Test
    func largeOutputIsTruncatedWithoutBlocking() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let script = try makeScript(
            in: directory,
            content: "/usr/bin/yes x | /usr/bin/head -c 300000\n",
            name: "大输出"
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForTerminal(execution, timeout: 8))

        #expect(execution.state == .succeeded)
        let stdout = try #require(execution.result?.stdout)
        #expect(stdout.contains("[输出已截断]"))
        #expect(stdout.utf8.count <= 256 * 1024 + 32)
    }

    @Test
    func workingDirectoryAndScriptPathArePassedToShell() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let workingDirectory = directory.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
        let script = try makeScript(
            in: directory,
            content: "printf '%s\\n%s\\n' \"$PWD\" \"$0\"\n",
            name: "路径",
            workingDirectory: workingDirectory
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let execution = try runScript(script, dispatcher: ActionDispatcher(registry: registry))
        #expect(await waitForTerminal(execution))

        let lines = try #require(execution.result?.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        #expect(lines.count == 3)
        #expect(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath() == workingDirectory.resolvingSymlinksInPath())
        #expect(lines[1] == script.url.path)
        #expect(lines[2].isEmpty)
    }

    @Test
    func processGroupCleanupUsesSigtermAndSigkillForTermIgnoringChild() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let groupFile = directory.appendingPathComponent("group.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let script = try makeScript(
            in: directory,
            content: "(trap '' TERM; while :; do sleep 1; done) & child=$!; trap '' TERM; printf '%s' \"$$\" > \"$GROUP_FILE\"; printf '%s' \"$child\" > \"$CHILD_FILE\"; while :; do sleep 1; done\n",
            name: "清理",
            timeout: 5,
            environment: ["GROUP_FILE": groupFile.path, "CHILD_FILE": childFile.path]
        )
        let registry = ActionRegistry()
        registry.register(ScriptActionProvider())
        let dispatcher = ActionDispatcher(registry: registry)
        let execution = try runScript(script, dispatcher: dispatcher)
        #expect(await waitForFile(groupFile))
        #expect(await waitForFile(childFile))
        let groupPID = readPID(at: groupFile)
        let childPID = readPID(at: childFile)
        defer {
            forceKillProcessGroup(groupPID)
            if let childPID, childPID > 1 { _ = kill(childPID, SIGKILL) }
        }

        execution.cancel()
        #expect(await waitForTerminal(execution, timeout: 8))
        #expect(execution.state == .cancelled)
        if let groupPID {
            #expect(await waitForProcessExit(groupPID, timeout: 3))
        }
        if let childPID {
            #expect(await waitForProcessExit(childPID, timeout: 3))
        }
    }

    @Test
    func normalExitStillCleansChildWithClosedOutputPipes() async throws {
        let directory = try makeScriptTestDirectory()
        defer { removeScriptTestDirectory(directory) }
        let groupFile = directory.appendingPathComponent("group.pid")
        let childFile = directory.appendingPathComponent("child.pid")
        let script = try makeScript(in: directory,
            content: "printf '%s' \"$$\" > \"$GROUP_FILE\"; (trap '' TERM HUP; while :; do sleep 1; done) >/dev/null 2>&1 & child=$!; printf '%s' \"$child\" > \"$CHILD_FILE\"; sleep 0.1; exit 0\n",
            name: "后台清理", interpreter: "/bin/bash",
            environment: ["GROUP_FILE": groupFile.path, "CHILD_FILE": childFile.path])
        let registry = ActionRegistry(); registry.register(ScriptActionProvider())
        let dispatcher = ActionDispatcher(registry: registry)
        let execution = try runScript(script, dispatcher: dispatcher)
        #expect(await waitForTerminal(execution))
        let groupPID = readPID(at: groupFile); let childPID = readPID(at: childFile)
        defer { forceKillProcessGroup(groupPID); if let childPID { _ = kill(childPID, SIGKILL) } }
        #expect(execution.state == .succeeded)
        let child = try #require(childPID)
        #expect(await waitForProcessExit(child))
    }
}
