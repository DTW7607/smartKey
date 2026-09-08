import Foundation
import Combine

public struct ShortcutReference: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
}

public struct ShortcutParameters: Sendable {
    public let id: UUID
    public let timeout: Double

    public init(action: ActionDefinition) throws {
        guard let raw = action.parameters["shortcutID"], let id = UUID(uuidString: raw) else {
            throw ActionError("请选择一个有效的快捷指令。")
        }
        guard let timeout = Double(action.parameters["timeout"] ?? "300"), timeout.isFinite,
              (1...3600).contains(timeout) else { throw ActionError("等待超时须为 1–3600 秒。") }
        self.id = id; self.timeout = timeout
    }
}

// Injectable boundary: tests never run the user's real shortcuts.
protocol ShortcutCommandRunning: Sendable {
    func run(arguments: [String], timeout: Double, waitingOnly: Bool) async throws -> ActionResult
}

struct ShortcutCommandRunner: ShortcutCommandRunning {
    func run(arguments: [String], timeout: Double, waitingOnly: Bool) async throws -> ActionResult {
        let job = ManagedProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await job.run {
                ManagedCommand(executable: "/usr/bin/shortcuts", arguments: arguments, timeout: timeout,
                               label: "快捷指令", stopsWaitingOnly: waitingOnly,
                               outputLimit: arguments.first == "list" ? 2 * 1024 * 1024 : 256 * 1024)
            }
        } onCancel: { job.stop(.cancelled) }
    }
}

@MainActor
public final class ShortcutActionProvider: ActionProvider {
    public let typeID = "shortcut"
    private var busy = false
    private let runner: any ShortcutCommandRunning
    public init() { runner = ShortcutCommandRunner() }
    init(runner: any ShortcutCommandRunning) { self.runner = runner }

    public func capabilities(for action: ActionDefinition) -> ActionCapabilities {
        ActionCapabilities(supportsCancellation: true, canVerifyResult: true)
    }
    public func validate(_ action: ActionDefinition, context: ActionContext) throws {
        _ = try ShortcutParameters(action: action)
        guard !busy else { throw ActionError("已有快捷指令运行中，请等待完成或先停止等待。") }
    }
    public func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try validate(action, context: context)
        let parameters = try ShortcutParameters(action: action)
        busy = true
        defer { busy = false }
        var result = try await runner.run(arguments: ["run", parameters.id.uuidString],
                                          timeout: parameters.timeout, waitingOnly: true)
        result.verified = result.exitCode == 0
        if result.exitCode == 0 {
            result.message = "系统报告快捷指令运行成功。"
        } else {
            let detail = String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            result.message = "快捷指令执行失败。" + (detail.isEmpty ? "请检查指令是否存在，并在快捷指令 App 中试运行。" : "\n" + detail)
        }
        return result
    }
}

@MainActor
public final class ShortcutCatalog: ObservableObject {
    @Published public private(set) var shortcuts: [ShortcutReference] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var error: String?
    private let runner: any ShortcutCommandRunning
    public init() { runner = ShortcutCommandRunner() }
    init(runner: any ShortcutCommandRunning) { self.runner = runner }

    public func refresh() async {
        // A quickly reopened editor waits for the cancelled request to release its process.
        while isLoading {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let result = try await runner.run(arguments: ["list", "--show-identifiers"], timeout: 15, waitingOnly: false)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw ActionError("无法读取快捷指令列表。请打开快捷指令 App 后重试。\n" + String(result.stderr.prefix(500)))
            }
            let parsed = try await Task.detached(priority: .userInitiated) { try Self.parse(result.stdout) }.value
            try Task.checkCancellation()
            shortcuts = parsed
            hasLoaded = true
        } catch is CancellationError {
            // Closing the editor cancels its list request without replacing the cache.
        } catch let failure as ActionRunError where failure.state == .cancelled {
        } catch {
            self.error = "加载快捷指令失败：" + error.localizedDescription
        }
    }

    public func open(_ id: UUID) async throws {
        let result = try await runner.run(arguments: ["view", id.uuidString], timeout: 15, waitingOnly: false)
        guard result.exitCode == 0 else { throw ActionError("无法打开快捷指令。" + String(result.stderr.prefix(500))) }
    }

    nonisolated static func parse(_ output: String) throws -> [ShortcutReference] {
        // Parse only a terminal UUID suffix; names may contain spaces, parentheses or newlines.
        let expression = try NSRegularExpression(pattern: #" \(([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\)(?:\r?\n|\z)"#)
        let source = output as NSString
        let matches = expression.matches(in: output, range: NSRange(location: 0, length: source.length))
        var end = 0
        var seen = Set<UUID>()
        var entries: [ShortcutReference] = []
        for match in matches {
            guard let id = UUID(uuidString: source.substring(with: match.range(at: 1))), seen.insert(id).inserted else {
                throw ActionError("快捷指令列表格式无法识别，请刷新重试。")
            }
            let name = source.substring(with: NSRange(location: end, length: match.range.location - end))
            guard !name.isEmpty else { throw ActionError("快捷指令名称为空。") }
            entries.append(ShortcutReference(id: id, name: name))
            end = NSMaxRange(match.range)
        }
        guard end == source.length else { throw ActionError("快捷指令列表不完整或格式无法识别，请刷新重试。") }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
