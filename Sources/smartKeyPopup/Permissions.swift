import AppKit
import Combine
import IOKit.hidsystem
import SmartKeyActions
import SwiftUI

enum AppPermission: String, CaseIterable, Identifiable {
    case inputMonitoring, accessibility

    var id: String { rawValue }
    var title: String { self == .inputMonitoring ? "输入监控" : "辅助功能" }
    var explanation: String {
        self == .inputMonitoring
            ? "用于接收智键线控的按键，识别单击、双击和长按。"
            : "用于执行键盘组合键、媒体控制等动作。授权后才会开放动作配置、脚本管理及动作执行。"
    }
    var settingsURL: URL {
        let pane = self == .inputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var granted: Set<AppPermission> = []
    @Published private(set) var inputMonitoringRequired = false
    @Published private(set) var notice: String?
    @Published private(set) var requested: Set<AppPermission> = []
    private(set) var noticePermission: AppPermission?
    private struct PromptHistory: Codable {
        var installationID: String
        var asked: Set<String> = []
    }
    private static let historyKey = "smartKey.permissions.promptHistory.v1"
    private let defaults: UserDefaults?
    private var history: PromptHistory
    private let check: @MainActor (AppPermission) -> Bool
    private let request: @MainActor (AppPermission) -> Void
    private let openSettings: @MainActor (URL) -> Bool

    init(check: @escaping @MainActor (AppPermission) -> Bool = PermissionsModel.systemCheck,
         request: @escaping @MainActor (AppPermission) -> Void = PermissionsModel.systemRequest,
         openSettings: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         defaults: UserDefaults? = nil, installationID: String = "development") {
        self.check = check
        self.request = request
        self.openSettings = openSettings
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode(PromptHistory.self, from: $0) }
        history = saved?.installationID == installationID ? saved! : PromptHistory(installationID: installationID)
    }

    static var installationID: String {
        Bundle.main.object(forInfoDictionaryKey: "SmartKeyInstallationID") as? String ?? "development"
    }

    var settingsPermissions: [AppPermission] {
        granted.contains(.inputMonitoring) ? [.accessibility, .inputMonitoring] : [.accessibility]
    }
    var canUseActions: Bool { granted.contains(.accessibility) }
    static let actionRestriction = "需要辅助功能授权；可在“通用 → 权限与启动”中开启。"

    func needsStartupGuidance(isPreview: Bool) -> Bool {
        guard !isPreview else { return false }
        refresh()
        return !canUseActions
    }

    /// Input Monitoring is only offered after a real access failure, once per
    /// installation/missing-permission episode. Accessibility is always guided
    /// on launch and deliberately does not use this suppression history.
    func takeInputMonitoringPrompt() -> Bool {
        refresh()
        let permission = AppPermission.inputMonitoring
        guard inputMonitoringRequired, !granted.contains(permission),
              !history.asked.contains(permission.rawValue) else { return false }
        history.asked.insert(permission.rawValue)
        persistHistory()
        return true
    }

    func reportInputMonitoringDenied() {
        inputMonitoringRequired = true
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults?.set(data, forKey: Self.historyKey) }
    }

    func refresh() {
        let next = Set(AppPermission.allCases.filter { check($0) })
        if granted != next { granted = next }
        let pendingRequests = requested.subtracting(next)
        if requested != pendingRequests { requested = pendingRequests }
        if next.contains(.inputMonitoring), inputMonitoringRequired { inputMonitoringRequired = false }
        // Observing a grant rearms exactly one invitation if access is later
        // revoked, including when that revocation occurs while the app is off.
        let rearmed = history.asked.subtracting(next.map(\.rawValue))
        if history.asked != rearmed { history.asked = rearmed; persistHistory() }
    }

    func authorize(_ permission: AppPermission) {
        refresh()
        guard !granted.contains(permission) else { return }
        notice = nil
        noticePermission = nil
        requested.insert(permission)
        request(permission)
        // The native permission prompt is asynchronous. Let its own button open
        // System Settings; an immediate false result is not a user refusal.
        refresh()
    }

    func openSystemSettings(_ permission: AppPermission) {
        notice = nil
        noticePermission = nil
        if !openSettings(permission.settingsURL) {
            noticePermission = permission
            notice = "请手动打开系统设置 → 隐私与安全性 → \(permission.title)，允许智键。"
        }
    }

    private static func systemCheck(_ permission: AppPermission) -> Bool {
        switch permission {
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .accessibility: return KeyboardActionProvider.isAuthorized
        }
    }

    private static func systemRequest(_ permission: AppPermission) {
        switch permission {
        case .inputMonitoring: _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .accessibility: KeyboardActionProvider.requestAuthorization()
        }
    }
}

@MainActor
struct PermissionControls: View {
    @ObservedObject var model: PermissionsModel
    var permissions: [AppPermission]? = nil
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(permissions ?? model.settingsPermissions) { permission in
              VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(permission.title).font(.headline)
                        Text(permission.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if model.granted.contains(permission) {
                        Label("已允许", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).fixedSize()
                    } else {
                        Button("去授权…") { model.authorize(permission) }
                            .accessibilityLabel("授权\(permission.title)").fixedSize()
                    }
                }
                if model.requested.contains(permission), !model.granted.contains(permission) {
                    Text("请在系统授权弹窗中选择“打开系统设置”。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("未看到弹窗？手动打开设置…") { model.openSystemSettings(permission) }
                        .font(.caption)
                }
              }
            }
            if let notice = model.notice, let permission = model.noticePermission,
               (permissions ?? model.settingsPermissions).contains(permission) {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            Text("在系统设置中开启“智键”或“smartKey”。若列表中没有应用，请点击“+”添加；若系统提示退出并重新打开，请按提示操作。")
                .font(.caption).foregroundStyle(.secondary)
            Button("刷新状态") { model.refresh() }
        }
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

@MainActor
private struct PermissionSetupView: View {
    @ObservedObject var model: PermissionsModel
    let permissions: [AppPermission]
    let dismiss: () -> Void
    let openSettings: () -> Void
    private var complete: Bool { permissions.allSatisfy { model.granted.contains($0) } }
    private var requiresAccessibility: Bool { permissions.contains(.accessibility) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Label("设置智键权限", systemImage: "hand.raised").font(.title2.bold())
                Text(requiresAccessibility
                     ? "辅助功能权限是使用智键动作的前提。未授权时可查看设置，关闭窗口后应用退出。"
                     : "系统阻止了线控按键访问。请允许输入监控，以接收智键按键。")
                    .foregroundStyle(.secondary)
            }
            PermissionControls(model: model, permissions: permissions)
            Divider()
            HStack {
                Text(complete ? "权限已就绪。" : (requiresAccessibility ? "请完成授权后继续。" : "暂不授权将无法接收受阻的线控按键。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if requiresAccessibility {
                    if !complete { Button("打开通用设置", action: openSettings) }
                    Button("开始使用", action: dismiss)
                        .keyboardShortcut(.defaultAction).disabled(!complete)
                } else {
                    Button(complete ? "完成" : "暂不授权", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(model: PermissionsModel, permissions: [AppPermission] = [.accessibility]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "智键权限设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PermissionSetupView(model: model, permissions: permissions,
            dismiss: { [weak self] in self?.close() }, openSettings: { [weak self] in self?.openSettings() }))
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        // Open the destination before closing the guide. This is a window
        // transition, not the user closing the last unauthorized window.
        onOpenSettings?()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let completion = onClose
        onClose = nil
        completion?()
    }
}
