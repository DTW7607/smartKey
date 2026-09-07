import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartKeyActions

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", bindings = "动作绑定", scripts = "脚本管理"
    var id: String { rawValue }
    var symbol: String { switch self { case .general: return "gearshape"; case .bindings: return "button.programmable"; case .scripts: return "terminal" } }
}

@MainActor
struct SmartKeySettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @AppStorage("smartKey.settings.section") private var savedSection = SettingsSection.bindings.rawValue
    private var selection: Binding<SettingsSection?> {
        Binding(get: { SettingsSection(rawValue: savedSection) ?? .bindings }, set: { if let value = $0 { savedSection = value.rawValue } })
    }
    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
                    .padding(.vertical, 5)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                Label(coordinator.store.document.paused ? "动作已暂停" : "智键", systemImage: coordinator.store.document.paused ? "pause.circle" : "button.programmable")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if let notice = coordinator.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { coordinator.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                    }.padding(14).background(.quaternary)
                }
                switch SettingsSection(rawValue: savedSection) ?? .bindings {
                case .general: GeneralSettingsView(coordinator: coordinator)
                case .bindings: BindingsSettingsView(coordinator: coordinator)
                case .scripts: ScriptsSettingsView(coordinator: coordinator)
                }
            }
            .navigationTitle(savedSection)
        }
        .onAppear { coordinator.refresh() }
        .frame(minWidth: 760, minHeight: 480)
    }
}

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @ObservedObject private var configuration: RuntimeConfiguration
    init(coordinator: ActionCoordinator) { self.coordinator = coordinator; self.configuration = coordinator.configuration }
    var body: some View {
        Form {
            Section("设备") {
                LabeledContent("连接状态", value: coordinator.deviceStatus)
                Button("重新配置设备…") { coordinator.onReconfigure?() }.disabled(coordinator.onReconfigure == nil)
                Toggle("暂停动作", isOn: Binding(get: { coordinator.store.document.paused }, set: { coordinator.setPaused($0) }))
                Text("暂停后不执行按键动作，保留当前设备模式与音频保护。").font(.caption).foregroundStyle(.secondary)
            }
            Section("手势") {
                LabeledContent("双击识别", value: coordinator.store.document.doubleClickEnabled ? "已开启 · 由绑定自动管理" : "已关闭 · 双击未绑定")
                timing("长按时长", key: "longPressMs", value: configuration.longPressMs, range: 300...1500)
                timing("双击判定窗口", key: "doubleClickMs", value: configuration.doubleClickMs, range: 150...800)
                Text("双击绑定动作后，单击需要等待判定窗口。长按到达阈值时执行一次。").font(.caption).foregroundStyle(.secondary)
            }
            Section("权限与启动") {
                LabeledContent("辅助功能", value: KeyboardActionProvider.isAuthorized ? "已允许" : "尚未允许")
                HStack {
                    Button("授权键盘与媒体控制…") { KeyboardActionProvider.requestAuthorization(); coordinator.openPermissions() }
                    Button("刷新状态") { coordinator.refresh() }
                }
                if LoginItem.isAvailable {
                    Toggle("登录时打开", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0); coordinator.objectWillChange.send() }))
                } else { Text("安装到 Applications 后可以设置登录时打开。").font(.caption).foregroundStyle(.secondary) }
            }
            Section("关于") { LabeledContent("智键", value: "首版 · macOS 26"); Text("一个实体按键，连接你的常用操作。").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private func timing(_ title: String, key: String, value: CGFloat, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            Text("\(Int(value)) ms").monospacedDigit().foregroundStyle(.secondary)
            Stepper("调整\(title)", value: Binding(get: { Double(value) }, set: { next in coordinator.perform { try configuration.write([key: next]) } }), in: range, step: 50)
                .labelsHidden().fixedSize()
        }
    }
}

@MainActor
struct BindingsSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @State private var editing: GestureSlot?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("为每种手势选择一个动作。名称会显示在触发气泡中。").foregroundStyle(.secondary)
                ForEach(GestureSlot.allCases) { slot in
                    GroupBox {
                        HStack(spacing: 18) {
                            Image(systemName: slot == .longPress ? "hand.point.up.left.fill" : "hand.tap")
                                .font(.title2).frame(width: 38).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(slot.title).font(.headline)
                                if let action = coordinator.store.document.action(for: slot) {
                                    Text(action.name).font(.title3.weight(.medium))
                                    Text(actionSummary(action)).font(.caption).foregroundStyle(.secondary)
                                } else { Text("无").foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let action = coordinator.store.document.action(for: slot) {
                                Button("测试") { coordinator.test(action) }.disabled(coordinator.testingKeyboard)
                            }
                            Menu {
                                Button("无") { coordinator.bind(nil, to: slot) }
                                Divider()
                                Button("选择或编辑动作…") { editing = slot }
                                if !coordinator.store.document.scripts.isEmpty {
                                    Menu("执行脚本") {
                                        ForEach(coordinator.store.document.scripts) { script in
                                            Button(script.name) { coordinator.bind(ActionDefinition(typeID: "script", name: script.name, parameters: ["scriptID": script.id.uuidString]), to: slot) }
                                        }
                                    }
                                }
                            } label: { Label("选择动作", systemImage: "slider.horizontal.3") }
                            .menuStyle(.borderlessButton).fixedSize().padding(9).glassEffect(.regular, in: .capsule)
                        }.padding(12)
                    }
                }
                Label(coordinator.store.document.doubleClickEnabled ? "双击已开启，单击需等待 \(Int(coordinator.configuration.doubleClickMs)) ms。" : "双击未绑定，单击松开即判定。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                if let execution = coordinator.lastExecution { ExecutionResultView(execution: execution) }
            }.padding(28)
        }
        .sheet(item: $editing) { slot in BindingEditor(coordinator: coordinator, slot: slot) }
    }
    private func actionSummary(_ action: ActionDefinition) -> String {
        switch action.typeID { case "keyboard": return "键盘 · \(action.parameters["display"] ?? "组合键")"; case "media": return "多媒体"; case "script": return "脚本 · 后台运行"; default: return "当前版本不支持此类型" }
    }
}

@MainActor
private struct BindingEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var coordinator: ActionCoordinator
    let slot: GestureSlot
    @Environment(\.dismiss) private var dismiss
    @State private var type = "keyboard"
    @State private var name = "键盘操作"
    @State private var keyCode: UInt16 = 0
    @State private var modifiers: UInt64 = 0
    @State private var keyDisplay = "A"
    @State private var operation = MediaOperation.playPause
    @State private var step = 5.0
    @State private var scriptID: UUID?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(slot.title)动作").font(.title2.bold())
            Form {
                Picker("动作类型", selection: $type) {
                    Text("键盘功能").tag("keyboard"); Text("多媒体功能").tag("media"); Text("执行脚本").tag("script")
                }.onChange(of: type) { _, value in name = value == "media" ? operation.title : "键盘操作" }
                if type != "script" {
                    TextField("动作名称", text: $name)
                    Text("\(name.count)/8 个字符").font(.caption).foregroundStyle(name.count > 8 ? .red : .secondary)
                }
                if type == "keyboard" {
                    KeyRecorder(keyCode: $keyCode, modifiers: $modifiers, display: $keyDisplay)
                    Text("录制一个单键或组合键，按 Escape 取消录制。").font(.caption).foregroundStyle(.secondary)
                } else if type == "media" {
                    Picker("操作", selection: $operation) { ForEach(MediaOperation.allCases) { Text($0.title).tag($0) } }
                        .onChange(of: operation) { _, value in name = value.title }
                    if operation == .volumeUp || operation == .volumeDown {
                        Stepper("音量步长：\(Int(step))%", value: $step, in: 1...100)
                    }
                    Text("播放目标由系统媒体路由决定。输出静音不影响麦克风。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("脚本", selection: $scriptID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(coordinator.store.document.scripts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if coordinator.store.document.scripts.isEmpty { Text("先到脚本管理中添加脚本。").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存绑定") { save() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 440)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: type)
            .onAppear { load() }
    }
    private func load() {
        guard let action = coordinator.store.document.action(for: slot) else { return }
        type = action.typeID; name = action.name
        keyCode = UInt16(action.parameters["keyCode"] ?? "0") ?? 0; modifiers = UInt64(action.parameters["modifiers"] ?? "0") ?? 0
        keyDisplay = action.parameters["display"] ?? "A"
        operation = MediaOperation(rawValue: action.parameters["operation"] ?? "") ?? .playPause
        step = Double(action.parameters["step"] ?? "5") ?? 5
        scriptID = action.parameters["scriptID"].flatMap(UUID.init(uuidString:))
    }
    private func save() {
        do {
            let action: ActionDefinition
            if type == "script" {
                guard let script = coordinator.store.document.scripts.first(where: { $0.id == scriptID }) else { throw ActionError("请选择一个脚本。") }
                action = ActionDefinition(typeID: type, name: script.name, parameters: ["scriptID": script.id.uuidString])
            } else {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); try ActionNames.validate(trimmed)
                action = ActionDefinition(typeID: type, name: trimmed, parameters: type == "keyboard" ?
                    ["keyCode": String(keyCode), "modifiers": String(modifiers), "display": keyDisplay] :
                    ["operation": operation.rawValue, "step": String(step)])
            }
            try coordinator.store.bind(action, to: slot); coordinator.refresh(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct KeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @Binding var display: String
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.bezelStyle = .rounded
        button.onKey = { code, flags, text in keyCode = code; modifiers = flags; display = text }
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) { if !button.recording { button.title = "录制快捷键：\(display)" } }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stopRecording() }
}

@MainActor
final class RecorderButton: NSButton {
    var onKey: ((UInt16, UInt64, String) -> Void)?
    private(set) var recording = false
    private var monitor: Any?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); target = self; action = #selector(record); setAccessibilityLabel("录制快捷键") }
    required init?(coder: NSCoder) { nil }
    @objc private func record() {
        if recording { stopRecording(); return }
        recording = true; title = "请按下组合键…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window == self.window else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let raw = UInt64(event.modifierFlags.rawValue) & KeyboardActionProvider.allowedFlags
            let f = event.modifierFlags
            let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let text = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + (special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "键 \(event.keyCode)")
            self.onKey?(event.keyCode, raw, text); self.stopRecording(); self.title = "录制快捷键：\(text)"
            return nil
        }
    }
    func stopRecording() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false; title = "录制快捷键" }
}

@MainActor
struct ExecutionResultView: View {
    @ObservedObject var execution: ActionExecution
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(execution.action.name) · \(execution.state.title)", systemImage: execution.state.symbol).font(.headline)
                    Spacer()
                    if execution.state == .running { ProgressView().controlSize(.small); Button("停止") { execution.cancel() } }
                }
                if let result = execution.result {
                    Text(result.message).font(.callout).textSelection(.enabled)
                    if !result.stdout.isEmpty || !result.stderr.isEmpty {
                        DisclosureGroup("查看输出") {
                            ScrollView([.vertical, .horizontal]) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if !result.stdout.isEmpty { Text(result.stdout).textSelection(.enabled) }
                                    if !result.stderr.isEmpty { Text("标准错误\n" + result.stderr).foregroundStyle(.red).textSelection(.enabled) }
                                }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 180)
                        }
                    }
                } else { Text("正在执行，可随时停止。").font(.caption).foregroundStyle(.secondary) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
