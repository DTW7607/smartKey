import Foundation
import ServiceManagement

enum LoginItem {
    private static let disabledKey = "smartKey.loginItemUserDisabled"

    /// Only the copy in /Applications is a valid SMAppService target.
    static var isAvailable: Bool {
        let url = Bundle.main.bundleURL
        return url.path.hasPrefix("/Applications/") && url.pathExtension == "app"
    }

    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func registerIfNeeded() {
        guard isAvailable else { return }
        if UserDefaults.standard.bool(forKey: disabledKey) { return }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return
        case .notRegistered, .notFound:
            try? SMAppService.mainApp.register()
        @unknown default: return
        }
    }

    static func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        UserDefaults.standard.set(!on, forKey: disabledKey)
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            fputs("智键登录项更新失败: \(error.localizedDescription)\n", stderr)
        }
    }
}
