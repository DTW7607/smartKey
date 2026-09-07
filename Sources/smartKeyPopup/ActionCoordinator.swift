import AppKit
import Combine
import SmartKeyActions

@MainActor
final class ActionCoordinator: ObservableObject {
    let store: ActionStore
    let library: ScriptLibrary
    let dispatcher: ActionDispatcher
    let configuration: RuntimeConfiguration
    @Published var notice: String?
    @Published var deviceStatus = "等待连接"
    @Published var deviceConnected = false
    @Published var remainingSeconds = 0
    @Published var hasAutomaticChoice = false
    @Published var preferredChoice = DeviceTypeChoice.smartKey
    @Published var isSuspended = false
    @Published var lastExecution: ActionExecution?
    @Published var testingKeyboard = false
    var onChooseAudioDevice: (() -> Void)?
    var onChooseSmartKey: (() -> Void)?
    var onBindingsChanged: (() -> Void)?
    var onFeedback: ((ActionExecution) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var sessionDocument: ActionDocument?
    private var sessionTarget: Int32?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var keyboardTest: Task<Void, Never>?
    private var suspensionReasons = Set<String>()
    var scriptDrafts: [UUID: (ScriptRecord, String)] = [:]

    init(configuration: RuntimeConfiguration, directory: URL) throws {
        self.configuration = configuration
        store = try ActionStore(directory: directory)
        library = try ScriptLibrary(directory: directory)
        let registry = ActionRegistry()
        registry.register(KeyboardActionProvider()); registry.register(MediaActionProvider()); registry.register(ScriptActionProvider())
        dispatcher = ActionDispatcher(registry: registry)
        notice = store.recoveryMessage
        store.$document.dropFirst().sink { [weak self] _ in
            // @Published emits before the stored document changes.
            DispatchQueue.main.async { self?.bindingsChanged() }
        }.store(in: &cancellables)
        configuration.$values.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.synchronizeDoubleClick() }
        }.store(in: &cancellables)
        library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        dispatcher.onChange = { [weak self] execution in
            self?.lastExecution = execution
            self?.objectWillChange.send()
            if execution.source == .physical { self?.onFeedback?(execution) }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("sleep", active: true) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("sleep", active: false); self?.refresh() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("session", active: true) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("session", active: false); self?.refresh() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("screen", active: true) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("screen", active: false) }
        })
        bindingsChanged()
    }
    deinit { for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    private func suspend(_ reason: String, active: Bool) {
        if active { suspensionReasons.insert(reason); keyboardTest?.cancel(); endSession() }
        else { suspensionReasons.remove(reason) }
        isSuspended = !suspensionReasons.isEmpty
    }

    func refresh() { library.refresh(store.document.scripts); synchronizeDoubleClick(); objectWillChange.send() }
    private func bindingsChanged() {
        library.refresh(store.document.scripts); synchronizeDoubleClick(); onBindingsChanged?(); objectWillChange.send()
    }
    func synchronizeDoubleClick() {
        let desired = store.document.doubleClickEnabled ? 1.0 : 0.0
        do { try configuration.write(["doubleClickEnabled": desired]) }
        catch { notice = "绑定已保存，但双击配置同步失败：\(error.localizedDescription)" }
    }
    func beginSession() {
        sessionDocument = store.document
        sessionTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    func endSession() { sessionDocument = nil; sessionTarget = nil }
    func runPhysical(_ slot: GestureSlot) {
        guard !store.document.paused, !isSuspended else { return }
        let document = sessionDocument ?? store.document
        guard !document.paused, let action = document.action(for: slot) else { return }
        dispatcher.cooldown = max(0, Double(configuration.bubbleHoldMs + configuration.bubbleDisappearMs + configuration.bubbleRetractCooldownMs) / 1000)
        dispatcher.run(action, context: context(for: action, document: document, source: .physical, target: sessionTarget))
    }
    private func context(for action: ActionDefinition, document: ActionDocument, source: ExecutionSource, target: Int32? = nil) -> ActionContext {
        let script = document.script(for: action)
        return ActionContext(source: source, targetPID: target, script: script, scriptURL: script.map { library.fileURL(for: $0) })
    }
    func test(_ action: ActionDefinition) {
        guard !isSuspended else { notice = "会话已暂停。"; return }
        if action.typeID == "keyboard" {
            keyboardTest?.cancel(); testingKeyboard = true
            notice = "请在 3 秒内切换到要接收按键的应用。"
            keyboardTest = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { self?.testingKeyboard = false; return }
                guard let self else { return }; testingKeyboard = false
                guard !isSuspended else { return }
                let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard target != ProcessInfo.processInfo.processIdentifier else { notice = "未切换到目标应用，已取消测试。"; return }
                dispatcher.run(action, context: context(for: action, document: store.document, source: .test, target: target))
            }
        } else { dispatcher.run(action, context: context(for: action, document: store.document, source: .test)) }
    }
    func testScript(_ script: ScriptRecord) { test(ActionDefinition(typeID: "script", name: script.name, parameters: ["scriptID": script.id.uuidString])) }
    func setPaused(_ paused: Bool) { perform { try store.change { $0.paused = paused } } }
    func perform(_ work: () throws -> Void) { do { try work() } catch { notice = error.localizedDescription } }
    func bind(_ action: ActionDefinition?, to slot: GestureSlot) { perform { try store.bind(action, to: slot); bindingsChanged() } }
    func saveScript(_ script: ScriptRecord) { perform { try store.saveScript(script); refresh() } }
    func moveScripts(from offsets: IndexSet, to destination: Int) { perform { try store.moveScripts(from: offsets, to: destination) } }
    func uniqueName(_ suggested: String) -> String {
        let trimmed = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = ActionNames.truncated(trimmed.isEmpty ? "新脚本" : trimmed)
        var result = candidate; var count = 2
        while store.document.scripts.contains(where: { $0.name.caseInsensitiveCompare(result) == .orderedSame }) {
            let suffix = String(count)
            result = ActionNames.truncated(candidate, maxUnits: ActionNames.maxUnits - suffix.count) + suffix
            count += 1
        }
        return result
    }
    @discardableResult
    func createScript() -> ScriptRecord? {
        let script = ScriptRecord(name: uniqueName("新脚本"))
        do {
            try library.createFile(for: script, content: Data("#!/bin/zsh\nprintf '你好，智键\\n'\n".utf8))
            do { try store.saveScript(script) } catch { try? library.removeFile(for: script); throw error }
            refresh(); return script
        } catch { notice = error.localizedDescription; return nil }
    }
    func importScript(_ url: URL) {
        perform {
            var script = url.pathExtension.lowercased() == "smartkeyscript" ? try ScriptLibrary.readPackageMetadata(at: url) : ScriptRecord(name: uniqueName(url.deletingPathExtension().lastPathComponent))
            script.id = UUID(); script.name = uniqueName(script.name)
            try library.importFile(url, for: script)
            do { try store.saveScript(script) } catch { try? library.removeFile(for: script); throw error }
            refresh()
        }
    }
    func duplicate(_ script: ScriptRecord) {
        var copy = script; copy.id = UUID(); copy.name = uniqueName(script.name)
        perform {
            try library.createFile(for: copy, content: ScriptLibrary.readSnapshot(at: library.fileURL(for: script)))
            do { try store.saveScript(copy) } catch { try? library.removeFile(for: copy); throw error }
            refresh()
        }
    }
    func delete(_ script: ScriptRecord) {
        guard dispatcher.runningScript?.action.parameters["scriptID"] != script.id.uuidString else { notice = "请先停止正在运行的脚本。"; return }
        perform {
            // Remove references first. An interrupted deletion can only leave an
            // unreferenced file, never a live binding to a removed script.
            try store.removeScript(script, unbind: true)
            try library.removeFile(for: script); scriptDrafts.removeValue(forKey: script.id); refresh(); bindingsChanged()
        }
    }
    func showImportPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "导入 Shell 脚本或智键脚本包，将复制到脚本库。"
        if panel.runModal() == .OK, let url = panel.url { importScript(url) }
    }
    func export(_ script: ScriptRecord, package: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = script.name + (package ? ".smartkeyscript" : ".sh")
        if panel.runModal() == .OK, let url = panel.url { perform { try library.exportFile(for: script, to: url, package: package) } }
    }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
