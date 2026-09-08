import SwiftUI
import AppKit
import SmartKeyActions

@MainActor
struct ShortcutBindingFields: View {
    @ObservedObject var catalog: ShortcutCatalog
    @Binding var shortcutID: UUID?
    @Binding var shortcutName: String
    @Binding var name: String
    @Binding var timeout: String
    @State private var showingList = false
    @State private var opening = false
    @State private var openError: String?

    private var selected: ShortcutReference? { catalog.shortcuts.first { $0.id == shortcutID } }
    private var missing: Bool { shortcutID != nil && selected == nil && catalog.hasLoaded && catalog.error == nil && !catalog.isLoading }
    private var selectionTitle: String {
        if let selected { return selected.name }
        guard shortcutID != nil else { return "请选择" }
        return (shortcutName.isEmpty ? "已绑定的快捷指令" : shortcutName) + (missing ? "（未找到）" : "")
    }

    var body: some View {
        LabeledContent("快捷指令") {
            Button { showingList = true } label: {
                HStack {
                    Text(selectionTitle).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .accessibilityLabel("快捷指令")
            .accessibilityValue(selectionTitle)
            .popover(isPresented: $showingList, arrowEdge: .bottom) {
                shortcutList
                    .task { await catalog.refresh() }
            }
        }
        Button("打开快捷指令") { openShortcutsApp() }.disabled(opening)
        if let openError { Text(openError).font(.caption).foregroundStyle(.red) }
        if missing {
            Text("未找到原快捷指令，可能已删除或尚未同步。重新展开列表可自动刷新；原绑定仍保留。")
                .font(.caption).foregroundStyle(.orange)
        }
        TextField("动作名称", text: $name)
        Text("\(ActionNames.unitCount(name))/\(ActionNames.maxUnits)，中文占 2 个字符")
            .font(.caption).foregroundStyle(.secondary)
        TextField("等待超时（秒，1–3600）", text: $timeout)
    }

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if catalog.isLoading {
                HStack { ProgressView().controlSize(.small); Text("正在更新快捷指令…").font(.caption) }
                    .padding(.horizontal, 8)
            }
            if let error = catalog.error {
                Text(error + "\n重新展开列表可重试。")
                    .font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
            }
            if catalog.hasLoaded && !catalog.isLoading && catalog.error == nil && catalog.shortcuts.isEmpty {
                Text("暂无快捷指令。请先在快捷指令 App 中创建或同步。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(catalog.shortcuts) { shortcut in
                        choice(displayName(shortcut), id: shortcut.id)
                    }
                }
            }
            .frame(height: min(CGFloat(catalog.shortcuts.count) * 34, 300))
        }
        .padding(8)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func choice(_ title: String, id: UUID) -> some View {
        ShortcutChoiceRow(title: title, selected: shortcutID == id) {
            let changed = shortcutID != id
            shortcutID = id
            if changed, let selected {
                shortcutName = selected.name
                let clean = selected.name.components(separatedBy: .controlCharacters).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                name = ActionNames.truncated(clean.isEmpty ? "快捷指令" : clean).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            showingList = false
        }
    }

    private func displayName(_ shortcut: ShortcutReference) -> String {
        let duplicate = catalog.shortcuts.filter { $0.name == shortcut.name }.count > 1
        return shortcut.name + (duplicate ? " · " + shortcut.id.uuidString.prefix(8) : "")
    }

    private func openShortcutsApp() {
        openError = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
            openError = "未找到快捷指令 App。"
            return
        }
        opening = true
        Task { @MainActor in
            defer { opening = false }
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            catch { openError = "无法打开快捷指令：" + error.localizedDescription }
        }
    }
}


@MainActor
private struct ShortcutChoiceRow: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.caption).frame(width: 14).opacity(selected ? 1 : 0)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .foregroundStyle(hovering || focused ? Color.white : Color.primary)
        .background(hovering || focused ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
