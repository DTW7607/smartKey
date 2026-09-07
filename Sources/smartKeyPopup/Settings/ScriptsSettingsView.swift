import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SmartKeyActions

@MainActor
struct ScriptsSettingsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    @State private var selected: UUID?
    @State private var dropTarget = false
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: ScriptRecord?
    @FocusState private var renameFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if coordinator.store.document.scripts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                        Text("添加第一个脚本").font(.headline).foregroundStyle(.secondary)
                        Text("拖入 Shell 文件，或新建脚本。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("导入脚本…") { coordinator.showImportPanel() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                } else {
                    List(selection: $selected) {
                        ForEach(coordinator.store.document.scripts) { script in
                            scriptRow(script).tag(script.id)
                        }
                        .onMove { source, destination in coordinator.moveScripts(from: source, to: destination) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .onDeleteCommand { pendingDelete = selectedScript }
                    Text(dropTarget ? "松开以导入" : "拖入文件以添加到脚本库")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .frame(width: 248)
            .frame(maxHeight: .infinity)
            .padding(.leading, 4)
            Divider()
            if let script = coordinator.store.document.scripts.first(where: { $0.id == selected }) {
                ScriptDetailsView(coordinator: coordinator, original: script, onDelete: { pendingDelete = script }).id(script.id)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(dropTarget ? Color.accentColor.opacity(0.1) : .clear)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            guard let first = providers.first else { return false }
            first.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in coordinator.importScript(url) } }
            }
            return true
        }
        .onAppear { if selected == nil { selected = coordinator.store.document.scripts.first?.id }; coordinator.refresh() }
        .onChange(of: coordinator.store.document.scripts) { _, scripts in
            if let selected, scripts.contains(where: { $0.id == selected }) { return }
            self.selected = scripts.first?.id
        }
        .confirmationDialog("删除“\(pendingDelete?.name ?? "")”？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("解除绑定并删除", role: .destructive) {
                if let script = pendingDelete {
                    if renaming == script.id { renaming = nil }
                    coordinator.delete(script)
                    if selected == script.id { selected = coordinator.store.document.scripts.first?.id }
                }
                pendingDelete = nil
            }
        } message: { Text("相关手势将设为“无”。") }
    }
    private var selectedScript: ScriptRecord? {
        coordinator.store.document.scripts.first(where: { $0.id == selected })
    }
    private var header: some View {
        HStack {
            Text("脚本库").font(.headline); Spacer()
            Button { selected = coordinator.createScript()?.id } label: { Image(systemName: "plus") }.accessibilityLabel("新建脚本")
            Button { coordinator.showImportPanel() } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入脚本")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    @ViewBuilder
    private func scriptRow(_ script: ScriptRecord) -> some View {
        if renaming == script.id {
            TextField("名称", text: $renameText)
                .focused($renameFocused)
                .onSubmit { commitRename(script) }
                .onExitCommand { renaming = nil }
                .onAppear { renameFocused = true }
                .onChange(of: renameFocused) { _, focused in if !focused && renaming == script.id { commitRename(script) } }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Label(script.name, systemImage: "terminal").font(.headline)
                Text(script.summary.isEmpty ? "Shell 脚本" : script.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.vertical, 5)
            .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = script.id; renameText = script.name })
        }
    }
    private func commitRename(_ script: ScriptRecord) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard trimmed != script.name else { return }
        var next = script
        next.name = trimmed
        coordinator.saveScript(next)
    }
}

@MainActor
struct ScriptDetailsView: View {
    @ObservedObject var coordinator: ActionCoordinator
    let original: ScriptRecord
    var onDelete: () -> Void = {}
    @State private var draft: ScriptRecord
    @State private var environmentText: String
    @State private var preview = ""
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    init(coordinator: ActionCoordinator, original: ScriptRecord, onDelete: @escaping () -> Void = {}) {
        self.coordinator = coordinator; self.original = original; self.onDelete = onDelete
        _draft = State(initialValue: coordinator.scriptDrafts[original.id]?.0 ?? original)
        _environmentText = State(initialValue: coordinator.scriptDrafts[original.id]?.1 ?? original.environment.keys.sorted().map { "\($0)=\(original.environment[$0]!)" }.joined(separator: "\n"))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.name).font(.title2.bold())
                        Text(coordinator.library.statuses[original.id] ?? "正在读取文件状态…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("在 Finder 中显示") { coordinator.library.reveal(original) }
                        Button("导出脚本文件…") { coordinator.export(original, package: false) }
                        Button("导出智键脚本包…") { coordinator.export(original, package: true) }
                        Divider()
                        Button("删除脚本…", role: .destructive) { onDelete() }
                    } label: { Image(systemName: "ellipsis.circle") }.fixedSize().accessibilityLabel("脚本操作")
                }
                HStack {
                    Button { coordinator.perform { try coordinator.library.openExternally(original) } } label: {
                        Label("使用默认应用打开", systemImage: "arrow.up.forward.app")
                            .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                    Spacer()
                    Button { coordinator.testScript(original) } label: {
                        Label("运行", systemImage: "play.fill")
                            .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                }
                GroupBox("脚本信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("名称", text: $draft.name)
                        Text("\(draft.name.count)/8 个字符，重命名会同步更新动作绑定。").font(.caption).foregroundStyle(draft.name.count > 8 ? .red : .secondary)
                        TextField("说明", text: $draft.summary, axis: .vertical).lineLimit(3...5)
                        Text("内容").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $preview)
                            .font(.system(.callout, design: .monospaced))
                            .disabled(true)
                            .frame(minHeight: 140, maxHeight: 220)
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
                    }.padding(8)
                }
                let references = coordinator.store.references(to: original)
                Label(references.isEmpty ? "尚未绑定手势" : "已绑定：" + references.map(\.title).joined(separator: "、"), systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary)
                if let execution = coordinator.dispatcher.executions.first(where: { $0.action.parameters["scriptID"] == original.id.uuidString }) {
                    ExecutionResultView(execution: execution)
                }
            }.padding(24)
        }
        .frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadPreview() }
        .onChange(of: coordinator.library.statuses[original.id]) { _, _ in loadPreview() }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: environmentText) { _, _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            save()
            coordinator.scriptDrafts[original.id] = (draft, environmentText)
        }
    }
    private func loadPreview() {
        do {
            preview = String(decoding: try ScriptLibrary.readSnapshot(at: coordinator.library.fileURL(for: original)), as: UTF8.self)
        } catch {
            preview = ""
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save()
        }
    }
    private func save() {
        do {
            var next = draft
            next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var environment: [String: String] = [:]
            for line in environmentText.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw ActionError("环境变量请使用 NAME=value 格式。") }
                environment[String(parts[0])] = String(parts[1])
            }
            next.environment = environment
            if let stored = coordinator.store.document.scripts.first(where: { $0.id == original.id }), stored == next {
                error = nil
                return
            }
            try next.validate(); try coordinator.store.saveScript(next); draft = next
            coordinator.scriptDrafts.removeValue(forKey: original.id); coordinator.refresh(); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
