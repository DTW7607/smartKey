import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartKeyActions

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", bindings = "动作配置", scripts = "脚本管理"
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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section).padding(.vertical, 5)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 180)
            .safeAreaInset(edge: .bottom) {
                Label(coordinator.deviceStatus, systemImage: coordinator.store.document.paused ? "pause.circle" : "button.programmable")
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
        .toolbar(removing: .sidebarToggle)
        .onAppear { coordinator.refresh() }
        .frame(minWidth: 800, idealWidth: 800, maxWidth: 800, minHeight: 520)
    }
}

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    var body: some View {
        Form {
            Section("设备") {
                LabeledContent("连接状态", value: coordinator.deviceStatus)
                if let model = coordinator.deviceSetup {
                    SettingsDeviceSetupView(coordinator: coordinator, model: model, configuration: coordinator.configuration)
                } else {
                    DeviceModeControls(coordinator: coordinator)
                }
                Toggle("暂停动作", isOn: Binding(get: { coordinator.store.document.paused }, set: { coordinator.setPaused($0) }))
            }
            Section("权限与启动") {
                LabeledContent("辅助功能", value: KeyboardActionProvider.isAuthorized ? "已允许" : "尚未允许")
                HStack {
                    Button("授权键盘与媒体控制…") { KeyboardActionProvider.requestAuthorization() }
                    Button("刷新状态") { coordinator.refresh() }
                }
                Toggle("登录时打开", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0); coordinator.objectWillChange.send() }))
            }
            Section("关于") { LabeledContent("智键", value: "首版 · macOS 26"); Text("一个实体按键，连接你的常用操作。").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

@MainActor
struct SettingsDeviceSetupView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @ObservedObject var model: DeviceSetupModel
    @ObservedObject var configuration: RuntimeConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceModeControls(coordinator: coordinator, allowsInteraction: model.presentationHost != .popup)
            Divider()
            Text("智键音频输出").font(.headline)
            Text("请选择其他设备播放声音。").font(.caption).foregroundStyle(.secondary)
            AudioDeviceTable(devices: model.outputs, selection: $model.selectedUID)
                .frame(height: configuration.setupTableHeightPt)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.12)))
                .disabled(!model.canEditSettingsOutput)

            if model.presentationHost == .popup {
                Label("请在设备选择窗口中完成设置。", systemImage: "macwindow")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if model.hasAutomaticOutputChoice, let first = model.outputs.first {
                    Text("\(model.remainingSeconds) 秒后自动使用第一项：\(first.name)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if model.outputs.isEmpty {
                    Text("暂无其他音频设备，请连接蓝牙或 USB 音频设备。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !model.canEditSettingsOutput && !model.isPresented {
                    Text("连接智键并选择智键模式后，可在这里设置音频输出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if [.applying, .applyingAudio, .activating].contains(model.stage) {
                        ProgressView().controlSize(.small)
                        Text(model.stage == .activating ? "等待线控设备…" : "正在切换音频输出…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isPresented {
                        Button("取消", action: model.cancel)
                    }
                    if model.stage == .audioError {
                        Button("重试", action: model.chooseAudioDevice)
                    } else if model.stage == .remoteError {
                        Button("重试", action: model.retryRemote)
                    }
                    Button("使用此设备", action: model.applySettingsOutput)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEditSettingsOutput || !model.outputs.contains { $0.uid == model.selectedUID })
                }
            }
        }
    }
}

@MainActor
private struct DeviceModeControls: View {
    @ObservedObject var coordinator: ActionCoordinator
    var allowsInteraction = true

    var body: some View {
        HStack(spacing: 12) {
            deviceModeCard("音频设备", symbol: "headphones", choice: .audioDevice,
                           action: { coordinator.onChooseAudioDevice?() })
            deviceModeCard("智键", symbol: "button.programmable", choice: .smartKey,
                           action: { coordinator.onChooseSmartKey?() })
        }.padding(.vertical, 4)
    }

    private func isSelected(_ choice: DeviceTypeChoice) -> Bool {
        if coordinator.hasAutomaticChoice { return coordinator.preferredChoice == choice }
        switch choice {
        case .audioDevice: return coordinator.deviceStatus == "音频设备"
        case .smartKey: return coordinator.deviceStatus == "智键"
        }
    }
    private func deviceModeCard(_ title: String, symbol: String, choice: DeviceTypeChoice, action: @escaping () -> Void) -> some View {
        let selected = isSelected(choice)
        let enabled = allowsInteraction && coordinator.deviceConnected && (choice == .audioDevice ? coordinator.onChooseAudioDevice : coordinator.onChooseSmartKey) != nil
        return VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 23))
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.1), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected && coordinator.hasAutomaticChoice {
                Text("\(coordinator.remainingSeconds)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Color.accentColor)
                    .padding(8)
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if enabled { action() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }
}

@MainActor
struct BindingsSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @ObservedObject private var configuration: RuntimeConfiguration
    @State private var editing: GestureSlot?
    @State private var longPressText = ""
    @State private var doubleClickText = ""
    @FocusState private var focusedTiming: String?
    init(coordinator: ActionCoordinator) { self.coordinator = coordinator; self.configuration = coordinator.configuration }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(GestureSlot.allCases) { slot in
                    let action = coordinator.store.document.action(for: slot)
                    GroupBox {
                        HStack(spacing: 18) {
                            Image(systemName: slot == .longPress ? "hand.point.up.left.fill" : "hand.tap")
                                .font(.title2).frame(width: 38).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(slot.title).font(.headline)
                                if let action {
                                    Text(action.name).font(.title3.weight(.medium))
                                    Text(actionSummary(action)).font(.caption).foregroundStyle(.secondary)
                                } else { Text("无").foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if action != nil {
                                Button("测试") { if let action { coordinator.test(action) } }.disabled(coordinator.testingKeyboard)
                            }
                            Button { editing = slot } label: {
                                Label("选择动作", systemImage: "slider.horizontal.3")
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .glassEffect(.regular, in: .capsule)
                        }.padding(12)
                    }
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(height: 36)
                        if slot == .doubleClick, action != nil {
                            Label("启用双击动作会影响按键的响应速度", systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .frame(height: 36)
                }
                GroupBox {
                    VStack(spacing: 10) {
                        timing("双击判定窗口", key: "doubleClickMs", text: $doubleClickText, defaultValue: 450, range: 150...800)
                        Divider()
                        timing("长按时长", key: "longPressMs", text: $longPressText, defaultValue: 450, range: 300...1500)
                    }.padding(8)
                }
                Color.clear.frame(height: 36)
                ForEach(coordinator.dispatcher.runningTasks) { execution in
                    ExecutionResultView(execution: execution)
                }
                if let execution = coordinator.lastExecution, execution.state != .running {
                    ExecutionResultView(execution: execution)
                }
            }.padding(28)
        }
        .sheet(item: $editing) { slot in BindingEditor(coordinator: coordinator, slot: slot) }
        .onAppear { longPressText = displayMs(configuration.longPressMs); doubleClickText = displayMs(configuration.doubleClickMs) }
        .onChange(of: configuration.longPressMs) { _, value in if focusedTiming != "longPressMs" { longPressText = displayMs(value) } }
        .onChange(of: configuration.doubleClickMs) { _, value in if focusedTiming != "doubleClickMs" { doubleClickText = displayMs(value) } }
    }
    private func actionSummary(_ action: ActionDefinition) -> String {
        switch action.typeID { case "keyboard": return "键盘 · \(action.parameters["display"] ?? "组合键")"; case "media": return "多媒体"; case "script": return "脚本 · 后台运行"; case "shortcut": return "快捷指令 · \(action.parameters["shortcutName"] ?? "执行快捷指令")"; default: return "当前版本不支持此类型" }
    }
    private func displayMs(_ value: CGFloat) -> String { String(Int(value)) }
    private func timing(_ title: String, key: String, text: Binding<String>, defaultValue: Double, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text, prompt: Text(String(Int(defaultValue))))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: 64)
                .focused($focusedTiming, equals: key)
                .onSubmit { commitTiming(key: key, text: text.wrappedValue, defaultValue: defaultValue, range: range) }
            Text("ms").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .onChange(of: focusedTiming) { previous, _ in
            if previous == key { commitTiming(key: key, text: text.wrappedValue, defaultValue: defaultValue, range: range) }
        }
    }
    private func commitTiming(key: String, text: String, defaultValue: Double, range: ClosedRange<Double>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Double
        if trimmed.isEmpty {
            parsed = defaultValue
        } else if let value = Double(trimmed), value.isFinite {
            parsed = min(max(value.rounded(), range.lowerBound), range.upperBound)
        } else {
            if key == "longPressMs" { longPressText = displayMs(configuration.longPressMs) }
            else { doubleClickText = displayMs(configuration.doubleClickMs) }
            return
        }
        let current = key == "longPressMs" ? Double(configuration.longPressMs) : Double(configuration.doubleClickMs)
        if parsed != current { coordinator.perform { try configuration.write([key: parsed]) } }
        if key == "longPressMs" { longPressText = displayMs(CGFloat(parsed)) }
        else { doubleClickText = displayMs(CGFloat(parsed)) }
    }
}

@MainActor
private struct BindingEditor: View {
    @ObservedObject var coordinator: ActionCoordinator
    let slot: GestureSlot
    @Environment(\.dismiss) private var dismiss
    @State private var type = "none"
    @State private var name = "键盘操作"
    @State private var keyCode: UInt16 = 0
    @State private var modifiers: UInt64 = 0
    @State private var keyDisplay = "A"
    @State private var operation = MediaOperation.playPause
    @State private var step = 5.0
    @State private var scriptID: UUID?
    @State private var shortcutID: UUID?
    @State private var shortcutName = ""
    @State private var shortcutTimeout = "300"
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(slot.title)动作").font(.title2.bold())
            Form {
                Picker("动作类型", selection: $type) {
                    Text("无").tag("none"); Text("键盘功能").tag("keyboard"); Text("多媒体功能").tag("media"); Text("执行脚本").tag("script"); Text("执行快捷指令").tag("shortcut")
                }
                if type == "keyboard" {
                    TextField("动作名称", text: $name)
                    Text("\(ActionNames.unitCount(name))/\(ActionNames.maxUnits)")
                        .font(.caption).foregroundStyle(ActionNames.unitCount(name) > ActionNames.maxUnits ? .red : .secondary)
                    KeyRecorder(keyCode: $keyCode, modifiers: $modifiers, display: $keyDisplay)
                } else if type == "media" {
                    Picker("操作", selection: $operation) { ForEach(MediaOperation.allCases) { Text($0.title).tag($0) } }
                    if operation == .volumeUp || operation == .volumeDown {
                        Stepper("音量步长：\(Int(step))%", value: $step, in: 1...100)
                    }
                } else if type == "shortcut" {
                    ShortcutBindingFields(catalog: coordinator.shortcuts, shortcutID: $shortcutID,
                                          shortcutName: $shortcutName, name: $name, timeout: $shortcutTimeout)
                } else if type == "script" {
                    Picker("脚本", selection: $scriptID) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(coordinator.store.document.scripts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if coordinator.store.document.scripts.isEmpty { Text("先到脚本管理中添加脚本。").foregroundStyle(.secondary) }
                }
            }
            .animation(nil, value: type)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存绑定") { save() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 440)
            .onAppear { load() }
            .onChange(of: type) { _, next in
                error = nil
                if next == "shortcut", shortcutID == nil, name == "键盘操作" { name = "快捷指令" }
            }
    }
    private func load() {
        guard let action = coordinator.store.document.action(for: slot) else { return }
        type = action.typeID; name = action.name
        keyCode = UInt16(action.parameters["keyCode"] ?? "0") ?? 0; modifiers = UInt64(action.parameters["modifiers"] ?? "0") ?? 0
        keyDisplay = action.parameters["display"] ?? "A"
        operation = MediaOperation(rawValue: action.parameters["operation"] ?? "") ?? .playPause
        step = Double(action.parameters["step"] ?? "5") ?? 5
        scriptID = action.parameters["scriptID"].flatMap(UUID.init(uuidString:))
        shortcutID = action.parameters["shortcutID"].flatMap(UUID.init(uuidString:))
        shortcutName = action.parameters["shortcutName"] ?? ""
        shortcutTimeout = action.parameters["timeout"] ?? "300"
    }
    private func save() {
        do {
            if type == "none" {
                try coordinator.store.bind(nil, to: slot); coordinator.refresh(); dismiss(); return
            }
            let action: ActionDefinition
            if type == "shortcut" {
                guard let shortcutID else { throw ActionError("请选择一个快捷指令。") }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try ActionNames.validate(trimmed)
                action = ActionDefinition(typeID: type, name: trimmed, parameters: [
                    "shortcutID": shortcutID.uuidString,
                    "shortcutName": coordinator.shortcuts.shortcuts.first(where: { $0.id == shortcutID })?.name ?? shortcutName,
                    "timeout": shortcutTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
                ])
                _ = try ShortcutParameters(action: action)
            } else if type == "script" {
                guard let script = coordinator.store.document.scripts.first(where: { $0.id == scriptID }) else { throw ActionError("请选择一个脚本。") }
                action = ActionDefinition(typeID: type, name: script.name, parameters: ["scriptID": script.id.uuidString])
            } else if type == "media" {
                action = ActionDefinition(typeID: type, name: operation.title, parameters: ["operation": operation.rawValue, "step": String(step)])
            } else if type == "keyboard" {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); try ActionNames.validate(trimmed)
                action = ActionDefinition(typeID: type, name: trimmed, parameters: ["keyCode": String(keyCode), "modifiers": String(modifiers), "display": keyDisplay])
            } else { throw ActionError("当前版本不支持此动作类型。") }
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
                    Label("\(execution.action.name) · \(execution.stateTitle)", systemImage: execution.state.symbol).font(.headline)
                    Spacer()
                    if execution.state == .running { ProgressView().controlSize(.small); Button(execution.action.typeID == "shortcut" ? "停止等待" : "停止") { execution.cancel() } }
                }
                if let result = execution.result {
                    Text(result.message).font(.callout).textSelection(.enabled)
                    if !result.stdout.isEmpty || !result.stderr.isEmpty {
                        ExecutionOutputView(stdout: result.stdout, stderr: result.stderr)
                    }
                } else { Text(execution.action.typeID == "shortcut" ? "正在等待系统执行；如需授权或输入，请在快捷指令 App 中完成。停止等待不会保证指令已停止。" : "正在执行，可随时停止。").font(.caption).foregroundStyle(.secondary) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
