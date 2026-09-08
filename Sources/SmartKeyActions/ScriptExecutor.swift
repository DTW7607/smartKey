import Foundation

@MainActor
public final class ScriptActionProvider: ActionProvider {
    public let typeID = "script"
    private var busy = false
    public init() {}
    public func capabilities(for action: ActionDefinition) -> ActionCapabilities { ActionCapabilities(supportsCancellation: true, canVerifyResult: true) }
    public func validate(_ action: ActionDefinition, context: ActionContext) throws {
        guard let script = context.script, context.scriptURL != nil else { throw ActionError("脚本文件或元信息不存在。") }
        try script.validate()
        guard !busy else { throw ActionError("已有脚本运行中，请等待完成或先停止。") }
    }
    public func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try validate(action, context: context)
        busy = true
        defer { busy = false }
        guard let script = context.script, let url = context.scriptURL else { throw ActionError("脚本不存在。") }
        let job = ManagedProcess()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await job.run {
                let data = try ScriptLibrary.readSnapshot(at: url)
                guard let content = String(data: data, encoding: .utf8) else { throw ActionError("脚本须为 UTF-8 文本。") }
                var environment = ManagedCommand.defaultEnvironment
                environment.merge(script.environment) { _, new in new }
                environment["SMARTKEY_SCRIPT_PATH"] = url.path
                environment["SMARTKEY_SCRIPT_DIR"] = url.deletingLastPathComponent().path
                return ManagedCommand(executable: script.interpreter, arguments: ["-c", content, url.path],
                    directory: script.workingDirectory.isEmpty ? url.deletingLastPathComponent().path : script.workingDirectory,
                    environment: environment, timeout: script.timeout, label: "脚本")
            }
        } onCancel: { job.stop(.cancelled) }
        return result
    }
}
