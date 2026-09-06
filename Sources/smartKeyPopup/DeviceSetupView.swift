import AppKit
import SmartKey
import SwiftUI

@available(macOS 26.0, *)
struct DeviceSetupView: View {
    @ObservedObject var model: DeviceSetupModel
    @ObservedObject var configuration: RuntimeConfiguration

    init(model: DeviceSetupModel, configuration: RuntimeConfiguration = RuntimeConfiguration()) {
        self.model = model
        self.configuration = configuration
    }

    private var choosingOutput: Bool {
        model.stage == .choosingOutput || (model.stage == .applying && !model.automaticallySelectingOutput)
    }
    private var audioMode: Bool { model.stage == .applyingAudio || model.stage == .audioError }
    private var title: String {
        if model.stage == .choosingType { return "监测到设备插入" }
        if choosingOutput { return "为智键选择音频输出" }
        if model.stage == .applying { return "正在切换音频输出" }
        if audioMode { return model.error == nil ? "正在切换到耳机" : "无法切换到耳机" }
        return model.stage == .remoteError ? "智键暂时无法连接" : "正在连接智键"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: model.stage == .choosingType || audioMode ? "headphones" : "button.programmable")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    if model.stage == .choosingType || choosingOutput {
                        Text(model.stage == .choosingType
                             ? "请选择插入 3.5 mm 端口的设备类型。"
                             : "请选择其他设备播放声音。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if model.stage == .choosingType {
                HStack(spacing: 12) {
                    typeChoice(.audioDevice, title: "音频设备", subtitle: "耳机或扬声器",
                               symbol: "headphones", action: model.chooseAudioDevice)
                    typeChoice(.smartKey, title: "智键", subtitle: "独占线控按键",
                               symbol: "button.programmable", action: model.chooseSmartKey)
                }
            } else {
                if choosingOutput {
                    AudioDeviceTable(devices: model.outputs, selection: $model.selectedUID)
                        .frame(height: configuration.setupTableHeightPt)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.08)))
                        .disabled(model.stage != .choosingOutput)
                }

                if let error = model.error {
                    Label(error, systemImage: model.stage == .activating ? "info.circle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(model.stage == .activating ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if choosingOutput && model.outputs.isEmpty {
                    Text("暂无其他音频设备。请连接蓝牙或 USB 音频设备后再选择。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                HStack {
                    if [.applying, .applyingAudio, .activating].contains(model.stage) {
                        ProgressView().controlSize(.small)
                        Text(model.stage == .activating ? "等待线控设备…" : "正在切换音频输出…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消", action: model.cancel).keyboardShortcut(.cancelAction)
                    if choosingOutput {
                        Button("使用此设备", action: model.applyOutput)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canApply)
                    } else if model.stage == .audioError {
                        Button("重试", action: model.chooseAudioDevice)
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    } else if model.stage == .remoteError || model.error != nil {
                        Button("重试", action: model.retryRemote)
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: choosingOutput ? configuration.setupOutputWidthPt : configuration.setupChoiceWidthPt)
        // A system window surface matches native controls and stays stable during
        // Spaces transitions; no desktop-dependent material fallback is involved.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: configuration.setupCornerRadiusPt))
        .overlay(RoundedRectangle(cornerRadius: configuration.setupCornerRadiusPt)
            .strokeBorder(.primary.opacity(0.12)))
        .padding(12)
    }

    @ViewBuilder
    private func typeChoice(_ choice: DeviceTypeChoice, title: String, subtitle: String,
                            symbol: String, action: @escaping () -> Void) -> some View {
        if model.preferredChoice == choice {
            deviceChoice(title, subtitle: subtitle, symbol: symbol, preferred: true, action: action)
                .keyboardShortcut(.defaultAction)
        } else {
            deviceChoice(title, subtitle: subtitle, symbol: symbol, action: action)
        }
    }

    private func deviceChoice(_ title: String, subtitle: String, symbol: String,
                              preferred: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 23))
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(preferred ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(preferred ? Color.accentColor : .primary.opacity(0.1), lineWidth: preferred ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if preferred && model.hasAutomaticChoice {
                    Text("\(model.remainingSeconds)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit().foregroundStyle(Color.accentColor)
                        .padding(8)
                        .accessibilityLabel("\(model.remainingSeconds) 秒后选择\(title)")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择\(title)")
    }
}

/// Use AppKit's actual system table for column headers, alternating rows,
/// keyboard selection, and the active/inactive selection colors in the reference.
private struct AudioDeviceTable: NSViewRepresentable {
    let devices: [SmartKeyAudioDevice]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 436, height: 174))
        table.autoresizingMask = [.width]
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "名称"
        name.width = 278
        let type = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        type.title = "类型"
        type.width = 142
        table.addTableColumn(name)
        table.addTableColumn(type)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("音频输出设备")
        let scroll = NSScrollView(frame: table.frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.updating = true
        context.coordinator.parent = self
        context.coordinator.enabled = context.environment.isEnabled
        table.reloadData()
        if let row = devices.firstIndex(where: { $0.uid == selection && !$0.isAnalogJack }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        context.coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AudioDeviceTable
        var updating = false
        var enabled = true
        init(_ parent: AudioDeviceTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.devices.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            enabled && !parent.devices[row].isAnalogJack
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            parent.selection = parent.devices.indices.contains(row) ? parent.devices[row].uid : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let device = parent.devices[row]
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? device.name : device.typeLabel)
            label.font = .systemFont(ofSize: 13)
            label.textColor = device.isAnalogJack ? .disabledControlTextColor : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            cell.toolTip = device.isAnalogJack ? "耳机端口用于智键，请选择其他音频设备" : device.name
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

private extension SmartKeyAudioDevice {
    var typeLabel: String {
        if isAnalogJack { return "耳机端口" }
        switch transport {
        case .builtIn: return "内建"
        case .bluetooth: return "蓝牙"
        case .usb: return "USB"
        case .displayPort: return "DisplayPort"
        case .hdmi: return "HDMI"
        case .airPlay: return "AirPlay"
        case .aggregate: return "聚集设备"
        case .virtual: return "虚拟设备"
        case .other: return "其他"
        }
    }
}
