import Foundation
import Darwin

public struct ActionRunError: LocalizedError, Sendable {
    public let state: ExecutionState
    public let result: ActionResult
    public var errorDescription: String? { result.message }
    public init(state: ExecutionState, result: ActionResult) { self.state = state; self.result = result }
}

// Preserve the existing public error name for script clients.
public typealias ScriptRunError = ActionRunError

struct ManagedCommand: Sendable {
    var executable: String
    var arguments: [String]
    var directory: String = FileManager.default.homeDirectoryForCurrentUser.path
    var environment: [String: String] = defaultEnvironment
    var timeout: Double
    var label: String
    var stopsWaitingOnly = false
    var outputLimit = 256 * 1024

    static var defaultEnvironment: [String: String] {
        ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
         "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }
    func stopMessage(_ state: ExecutionState) -> String {
        if stopsWaitingOnly {
            return (state == .timedOut ? "超过 \(Int(timeout)) 秒，已停止等待。" : "已停止等待。")
                + "快捷指令可能仍在系统中运行，请到快捷指令 App 检查。"
        }
        return state == .timedOut ? "超过 \(Int(timeout)) 秒，已停止任务。" : "任务已停止。"
    }
}

/// Runs an executable with literal arguments and an owned process group. stdin is /dev/null.
final class ManagedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var reason: ExecutionState?
    private var completed = false
    private var parentExitedAt: Date?
    private var output = Data()
    private var errors = Data()
    private var truncated = [false, false]
    private var limit = 256 * 1024

    func stop(_ state: ExecutionState) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if reason == nil { reason = state }
        let processID = pid
        lock.unlock()
        if processID > 0 {
            kill(-processID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); let shouldKill = !completed; lock.unlock()
                if shouldKill { kill(-processID, SIGKILL) }
            }
        }
    }

    func run(_ prepare: @escaping @Sendable () throws -> ManagedCommand) async throws -> ActionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { continuation.resume(returning: try runBlocking(try prepare())) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func runBlocking(_ command: ManagedCommand) throws -> ActionResult {
        lock.lock(); let cancelledBeforeStart = reason; lock.unlock()
        if let state = cancelledBeforeStart {
            throw ActionRunError(state: state, result: ActionResult(command.stopMessage(state), verified: false))
        }
        let cwd = command.directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ActionError("工作目录不存在：\(cwd)")
        }
        let args = [command.executable] + command.arguments
        let env = command.environment
        guard !args.contains(where: { $0.contains("\0") }),
              !env.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }) else {
            throw ActionError("进程参数无效。")
        }
        limit = command.outputLimit
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ActionError("无法创建输出管道。") }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); throw ActionError("无法创建错误管道。") }
        let nullFD = open("/dev/null", O_RDONLY)
        defer { if nullFD >= 0 { close(nullFD) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var child: pid_t = 0
        let spawnResult = withCStringArray(args) { argv in
            withCStringArray(env.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&child, command.executable, &actions, &attributes, argv, envp)
            }
        }
        close(outPipe[1]); close(errPipe[1])
        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ActionError("\(command.label)启动失败：\(String(cString: strerror(spawnResult)))")
        }
        lock.lock(); pid = child; let pendingStop = reason; lock.unlock()
        if let pendingStop { stop(pendingStop) }
        let timeout = DispatchWorkItem { [self] in stop(.timedOut) }
        DispatchQueue.global().asyncAfter(wallDeadline: .now() + command.timeout, execute: timeout)
        let readers = DispatchGroup()
        for (index, fd) in [outPipe[0], errPipe[0]].enumerated() {
            readers.enter()
            DispatchQueue.global().async { [self] in drain(fd, index: index); readers.leave() }
        }
        var waitStatus: Int32 = 0
        while waitpid(child, &waitStatus, 0) < 0 { if errno != EINTR { break } }
        lock.lock(); parentExitedAt = Date(); lock.unlock()
        // Clean up only this process group; system Shortcuts services are outside it.
        kill(-child, SIGTERM)
        // Finish group cleanup before reporting completion, even if a child
        // redirected stdout/stderr and therefore no longer holds our pipes.
        if kill(-child, 0) == 0 {
            for _ in 0..<10 {
                if kill(-child, 0) != 0 { break }
                usleep(20_000)
            }
            kill(-child, SIGKILL)
        }
        readers.wait()
        timeout.cancel()
        lock.lock()
        completed = true
        let why = reason
        let stdout = ProcessOutput.describe(output, truncated: truncated[0])
        let stderr = ProcessOutput.describe(errors, truncated: truncated[1])
        lock.unlock()
        let signal = waitStatus & 0x7f
        let code = signal == 0 ? ((waitStatus >> 8) & 0xff) : 128 + signal
        let result = ActionResult(why.map(command.stopMessage) ?? "\(command.label)退出码：\(code)",
                                  verified: why == nil, exitCode: code, stdout: stdout, stderr: stderr)
        if let why { throw ActionRunError(state: why, result: result) }
        return result
    }

    private func drain(_ fd: Int32, index: Int) {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 50)
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                lock.lock()
                let held = index == 0 ? output.count : errors.count
                let keep = min(count, max(0, limit - held))
                if index == 0 { output.append(contentsOf: bytes.prefix(keep)) } else { errors.append(contentsOf: bytes.prefix(keep)) }
                if keep < count { truncated[index] = true }
                lock.unlock()
            } else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { break }
            lock.lock(); let end = parentExitedAt; lock.unlock()
            if let end, Date().timeIntervalSince(end) > 1.5 { break }
        }
    }

    private func withCStringArray<T>(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = values.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
