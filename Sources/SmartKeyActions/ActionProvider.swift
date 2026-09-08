import Foundation
import Combine

public enum ExecutionSource: Sendable { case physical, test }
public struct ActionContext: Sendable {
    public var source: ExecutionSource
    public var targetPID: Int32?
    public var script: ScriptRecord?
    public var scriptURL: URL?
    public init(source: ExecutionSource, targetPID: Int32? = nil, script: ScriptRecord? = nil, scriptURL: URL? = nil) {
        self.source = source; self.targetPID = targetPID; self.script = script; self.scriptURL = scriptURL
    }
}

public struct ActionResult: Sendable {
    public var message: String
    public var verified: Bool
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    public init(_ message: String, verified: Bool = false, exitCode: Int32? = nil, stdout: String = "", stderr: String = "") {
        self.message = message; self.verified = verified; self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public struct ActionCapabilities: Sendable {
    public var permissions: [String]
    public var supportsCancellation: Bool
    public var canVerifyResult: Bool
    public init(permissions: [String] = [], supportsCancellation: Bool = false, canVerifyResult: Bool = false) {
        self.permissions = permissions; self.supportsCancellation = supportsCancellation; self.canVerifyResult = canVerifyResult
    }
}

public enum ExecutionState: String, Sendable {
    case running, sent, succeeded, failed, cancelled, timedOut
    public var title: String {
        switch self { case .running: return "运行中"; case .sent: return "已发送"; case .succeeded: return "已完成"
        case .failed: return "失败"; case .cancelled: return "已停止"; case .timedOut: return "已超时" }
    }
    public var symbol: String {
        switch self { case .running: return "ellipsis"; case .sent: return "paperplane"; case .succeeded: return "checkmark"
        case .failed: return "exclamationmark.triangle"; case .cancelled: return "stop.fill"; case .timedOut: return "clock.badge.exclamationmark" }
    }
}

@MainActor
public final class ActionExecution: ObservableObject, Identifiable {
    public let id = UUID()
    public let action: ActionDefinition
    public let source: ExecutionSource
    public let startedAt = Date()
    @Published public private(set) var state: ExecutionState = .running
    @Published public private(set) var result: ActionResult?
    @Published public private(set) var finishedAt: Date?
    private var task: Task<Void, Never>?
    init(action: ActionDefinition, source: ExecutionSource) { self.action = action; self.source = source }
    public var stateTitle: String {
        action.typeID == "shortcut" && state == .cancelled ? "已停止等待" : state.title
    }
    public func cancel() { task?.cancel() }
    func attach(_ task: Task<Void, Never>) { self.task = task }
    func finish(_ state: ExecutionState, result: ActionResult) {
        self.result = result; self.state = state; finishedAt = Date(); task = nil
    }
}

@MainActor
public protocol ActionProvider: AnyObject {
    var typeID: String { get }
    var supportedVersions: ClosedRange<Int> { get }
    func capabilities(for action: ActionDefinition) -> ActionCapabilities
    func validate(_ action: ActionDefinition, context: ActionContext) throws
    func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult
}

public extension ActionProvider {
    var supportedVersions: ClosedRange<Int> { 1...1 }
    func capabilities(for action: ActionDefinition) -> ActionCapabilities { ActionCapabilities() }
}

@MainActor
public final class ActionRegistry {
    private var providers: [String: any ActionProvider] = [:]
    public init() {}
    public func register(_ provider: any ActionProvider) { providers[provider.typeID] = provider }
    public func provider(for action: ActionDefinition) throws -> any ActionProvider {
        guard let provider = providers[action.typeID], provider.supportedVersions.contains(action.version) else { throw ActionError("当前版本不支持此动作类型或参数版本。") }
        return provider
    }
}

@MainActor
public final class ActionDispatcher: ObservableObject {
    @Published public private(set) var executions: [ActionExecution] = []
    public let registry: ActionRegistry
    public var onChange: ((ActionExecution) -> Void)?
    public var cooldown: TimeInterval = 0.02
    private var nextPhysicalAt: TimeInterval = 0
    private let now: () -> TimeInterval
    public init(registry: ActionRegistry, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.registry = registry; self.now = now
    }
    @discardableResult
    public func run(_ action: ActionDefinition?, context: ActionContext) -> ActionExecution? {
        guard let action else { return nil }
        if context.source == .physical {
            guard now() >= nextPhysicalAt else { return nil }
            nextPhysicalAt = now() + max(cooldown, 0)
        }
        let execution = ActionExecution(action: action, source: context.source)
        executions.insert(execution, at: 0)
        if executions.count > 100 {
            let keep = Set(executions.prefix(100).map(\.id))
            executions.removeAll { $0.finishedAt != nil && !keep.contains($0.id) }
        }
        onChange?(execution)
        let task = Task { [self, execution] in
            do {
                try Task.checkCancellation(); try ActionNames.validate(action.name)
                let provider = try registry.provider(for: action)
                try provider.validate(action, context: context)
                let result = try await provider.execute(action, context: context)
                if Task.isCancelled { execution.finish(.cancelled, result: result) }
                else { execution.finish(result.exitCode.map { $0 == 0 } == false ? .failed : (result.verified ? .succeeded : .sent), result: result) }
            } catch is CancellationError {
                let message = action.typeID == "shortcut" ? "已停止等待。快捷指令可能仍在系统中运行，请到快捷指令 App 检查。" : "任务已停止。"
                execution.finish(.cancelled, result: ActionResult(message))
            }
            catch let error as ActionRunError { execution.finish(error.state, result: error.result) }
            catch { execution.finish(.failed, result: ActionResult(error.localizedDescription)) }
            onChange?(execution)
        }
        execution.attach(task)
        return execution
    }
    public var runningScript: ActionExecution? { executions.first { $0.action.typeID == "script" && $0.state == .running } }
    public var runningTasks: [ActionExecution] { executions.filter { $0.state == .running } }
    public func cancelAll() { executions.filter { $0.state == .running }.forEach { $0.cancel() } }
}
