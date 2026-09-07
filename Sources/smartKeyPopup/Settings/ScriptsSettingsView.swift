import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartKeyActions

@MainActor
struct ScriptsSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @State private var selected: UUID?
    @State private var dropTarget = false
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("脚本库").font(.headline); Spacer()
                    Button { selected = coordinator.createScript()?.id } label: { Image(systemName: "plus") }.accessibilityLabel("新建脚本")
                    Button { coordinator.showImportPanel() } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入脚本")
                }.padding(16)
                if coordinator.store.document.scripts.isEmpty {
                    ContentUnavailableView { Label("添加第一个脚本", systemImage: "terminal") } description: {
                        Text("拖入 Shell 文件，或新建脚本后用默认应用编辑。")
                    } actions: { Button("导入脚本…") { coordinator.showImportPanel() } }.controlSize(.small)
                } else {
                    List(coordinator.store.document.scripts, selection: $selected) { script in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(script.name, systemImage: "terminal").font(.headline)
                            Text(script.summary.isEmpty ? "Shell 脚本" : script.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 5).tag(script.id)
                    }
                }
                Text(dropTarget ? "松开以导入" : "拖入文件以添加到脚本库").font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .frame(minWidth: 205, idealWidth: 235, maxWidth: 290, maxHeight: .infinity)
            .background(dropTarget ? Color.accentColor.opacity(0.1) : .clear)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                guard let first = providers.first else { return false }
                first.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { Task { @MainActor in coordinator.importScript(url) } }
                }
                return true
            }
            if let script = coordinator.store.document.scripts.first(where: { $0.id == selected }) {
                ScriptDetailsView(coordinator: coordinator, original: script).id(script.id)
            } else {
                ContentUnavailableView("选择一个脚本", systemImage: "doc.text", description: Text("查看说明、打开文件，或试运行已保存的脚本。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear { if selected == nil { selected = coordinator.store.document.scripts.first?.id }; coordinator.refresh() }
    }
}

@MainActor
struct ScriptDetailsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    let original: ScriptRecord
    @State private var draft: ScriptRecord
    @State private var environmentText: String
    @State private var deleteConfirmation = false
    @State private var error: String?
    init(coordinator: ActionCoordinator, original: ScriptRecord) {
        self.coordinator = coordinator; self.original = original
        _draft = State(initialValue: coordinator.scriptDrafts[original.id]?.0 ?? original)
        _environmentText = State(initialValue: coordinator.scriptDrafts[original.id]?.1 ?? original.environment.keys.sorted().map { "\($0)=\(original.environment[$0]!)" }.joined(separator: "\n"))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(original.name).font(.title2.bold())
                        Text(coordinator.library.statuses[original.id] ?? "正在读取文件状态…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("在 Finder 中显示") { coordinator.library.reveal(original) }
                        Button("复制脚本") { coordinator.duplicate(original) }
                        Button("导出脚本文件…") { coordinator.export(original, package: false) }
                        Button("导出智键脚本包…") { coordinator.export(original, package: true) }
                        Divider()
                        Button("删除脚本…", role: .destructive) { deleteConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }.fixedSize().accessibilityLabel("脚本操作")
                }
                HStack {
                    Button { coordinator.perform { try coordinator.library.openExternally(original) } } label: {
                        Label("用默认应用打开…", systemImage: "arrow.up.forward.app")
                    }.buttonStyle(.glass)
                    Spacer()
                    Button { coordinator.testScript(original) } label: { Label("试运行", systemImage: "play.fill") }
                        .buttonStyle(.glassProminent)
                }
                Text("默认应用：\(coordinator.library.defaultApplicationName(for: original) ?? "尚未关联")。内容在外部应用中预览和编辑；保存后再试运行。").font(.caption).foregroundStyle(.secondary)
                if (coordinator.library.defaultApplicationName(for: original) ?? "").lowercased().contains("terminal") {
                    Text("当前默认应用是终端，打开文件可能执行脚本。可在 Finder 中调整此类文件的默认打开应用。").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("脚本信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("名称", text: $draft.name)
                        Text("\(draft.name.count)/8 个字符，重命名会同步更新动作绑定。").font(.caption).foregroundStyle(draft.name.count > 8 ? .red : .secondary)
                        TextField("说明", text: $draft.summary, axis: .vertical).lineLimit(3...5)
                        Picker("解释器", selection: $draft.interpreter) { Text("zsh").tag("/bin/zsh"); Text("bash").tag("/bin/bash") }
                        TextField("工作目录（留空使用脚本所在目录）", text: $draft.workingDirectory)
                        HStack {
                            Text("超时（秒）")
                            TextField("30", value: $draft.timeout, format: .number).frame(width: 85)
                        }
                        DisclosureGroup("环境变量") {
                            TextField("每行 NAME=value", text: $environmentText, axis: .vertical).font(.system(.callout, design: .monospaced)).lineLimit(3...8)
                            Text("配置保存在本机。请勿在此保存密码或令牌。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error { Text(error).font(.callout).foregroundStyle(.red) }
                        HStack {
                            if draft != original || environmentText != original.environment.keys.sorted().map({ "\($0)=\(original.environment[$0]!)" }).joined(separator: "\n") {
                                Text("信息尚未保存").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Button("保存信息") { save() }.keyboardShortcut("s", modifiers: .command)
                        }
                    }.padding(8)
                }
                let references = coordinator.store.references(to: original)
                Label(references.isEmpty ? "尚未绑定手势" : "已绑定：" + references.map(\.title).joined(separator: "、"), systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary)
                Text("试运行与实体按键都运行磁盘上已保存的脚本，并使用已保存的运行参数。").font(.caption).foregroundStyle(.secondary)
                if let execution = coordinator.dispatcher.executions.first(where: { $0.action.parameters["scriptID"] == original.id.uuidString }) {
                    ExecutionResultView(execution: execution)
                }
            }.padding(24)
        }
        .frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { coordinator.scriptDrafts[original.id] = (draft, environmentText) }
        .confirmationDialog("删除“\(original.name)”？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("解除绑定并删除", role: .destructive) { coordinator.delete(original) }
        } message: { Text("相关手势将设为“无”；双击绑定被移除后，双击识别会自动关闭。") }
    }
    private func save() {
        do {
            var environment: [String: String] = [:]
            for line in environmentText.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw ActionError("环境变量请使用 NAME=value 格式。") }
                environment[String(parts[0])] = String(parts[1])
            }
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.environment = environment
            try draft.validate(); try coordinator.store.saveScript(draft); coordinator.scriptDrafts.removeValue(forKey: original.id); coordinator.refresh(); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
