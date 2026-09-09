import AppKit
import Testing
import SwiftUI
import SmartKeyActions
@testable import smartKeyPopup

@Suite @MainActor
struct PermissionsTests {
    @Test func inputPromptRequiresAnAccessFailureAndRefusalSurvivesRelaunch() throws {
        let suite = "smartKey-permissions-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var granted: Set<AppPermission> = [.accessibility]
        func makeModel(installationID: String = "first") -> PermissionsModel {
            PermissionsModel(check: { granted.contains($0) }, defaults: defaults, installationID: installationID)
        }
        let model = makeModel()
        #expect(!model.takeInputMonitoringPrompt())
        model.reportInputMonitoringDenied()
        #expect(model.takeInputMonitoringPrompt())
        #expect(!model.takeInputMonitoringPrompt())
        #expect(model.settingsPermissions == [.accessibility])

        let relaunched = makeModel()
        relaunched.reportInputMonitoringDenied()
        #expect(!relaunched.takeInputMonitoringPrompt())
        // Accessibility never inherits Input Monitoring's refusal record.
        granted = []
        #expect(relaunched.needsStartupGuidance(isPreview: false))
        #expect(makeModel().needsStartupGuidance(isPreview: false))

        granted = Set(AppPermission.allCases)
        relaunched.refresh()
        #expect(relaunched.settingsPermissions == [.accessibility, .inputMonitoring])
        granted = [.accessibility]
        relaunched.refresh()
        #expect(relaunched.settingsPermissions == [.accessibility])
        #expect(!relaunched.takeInputMonitoringPrompt())
        relaunched.reportInputMonitoringDenied()
        #expect(relaunched.takeInputMonitoringPrompt())

        let reinstalled = makeModel(installationID: "second")
        #expect(!reinstalled.takeInputMonitoringPrompt())
        reinstalled.reportInputMonitoringDenied()
        #expect(reinstalled.takeInputMonitoringPrompt())
    }

    @Test func missingAccessibilityAllowsBrowsingEveryPageButOnlyGeneralIsEditable() {
        for saved in SettingsSection.allCases {
            #expect(SettingsSection.availableSelection(saved: saved.rawValue, canUseActions: false) == saved)
            #expect(SettingsSection.availableSelection(saved: saved.rawValue, canUseActions: true) == saved)
            #expect(saved.isAvailable(canUseActions: false) == (saved == .general))
        }
        #expect(SettingsSection.availableSelection(saved: "unknown", canUseActions: false) == .general)
    }

    @Test func revokedPermissionBlocksBindingsScriptsAndExecutionWithoutRemovingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-permission-gates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let model = PermissionsModel(check: { $0 == .accessibility && allowed })
        let config = RuntimeConfiguration.load(url: directory.appendingPathComponent("smartKey.conf"))
        let coordinator = try ActionCoordinator(configuration: config, directory: directory, permissions: model)
        let script = try #require(coordinator.createScript())
        let action = ActionDefinition(typeID: "script", name: script.name, parameters: ["scriptID": script.id.uuidString])
        coordinator.bind(action, to: .singleClick)
        let saved = coordinator.store.document
        let originalFile = try Data(contentsOf: coordinator.library.fileURL(for: script))
        coordinator.beginSession()
        allowed = false
        // Execution and mutations recheck authorization even before UI polling.
        coordinator.runPhysical(.singleClick)
        for type in ["script", "keyboard", "media", "shortcut"] {
            coordinator.test(ActionDefinition(typeID: type, name: "受限动作", parameters: action.parameters))
        }
        #expect(coordinator.dispatcher.executions.isEmpty)
        #expect(!coordinator.testingKeyboard)
        #expect(coordinator.createScript() == nil)
        coordinator.importScript(coordinator.library.fileURL(for: script))
        coordinator.duplicate(script)
        coordinator.delete(script)
        var renamed = script
        renamed.name = "不应保存"
        coordinator.saveScript(renamed)
        coordinator.bind(nil, to: .singleClick)
        #expect(coordinator.store.document == saved)
        #expect(try Data(contentsOf: coordinator.library.fileURL(for: script)) == originalFile)
        #expect(!coordinator.canUseActions)
        #expect(coordinator.notice == PermissionsModel.actionRestriction)

        allowed = true
        coordinator.refresh()
        #expect(coordinator.canUseActions)
        #expect(coordinator.createScript() != nil)
        #expect(coordinator.store.document.action(for: .singleClick) == action)
    }

    @Test func startupChecksCurrentPermissionsEveryLaunch() {
        var granted = Set(AppPermission.allCases)
        let model = PermissionsModel(check: { granted.contains($0) }, request: { _ in
            Issue.record("Startup must not request access without a user action")
        }, openSettings: { _ in
            Issue.record("Startup must not open System Settings")
            return true
        })
        #expect(!model.needsStartupGuidance(isPreview: false))
        granted = [.accessibility]
        #expect(!model.needsStartupGuidance(isPreview: false))
        #expect(!model.takeInputMonitoringPrompt())
        granted = [.inputMonitoring]
        #expect(model.needsStartupGuidance(isPreview: false))
        #expect(model.needsStartupGuidance(isPreview: false))
        granted = []
        #expect(model.needsStartupGuidance(isPreview: false))
    }

    @Test func previewSkipsStartupChecks() {
        let model = PermissionsModel(check: { _ in
            Issue.record("Settings preview must skip startup permission checks")
            return false
        })
        #expect(!model.needsStartupGuidance(isPreview: true))
    }

    @Test func requestingAuthorizationNeverOpensSettingsBeforeUserInteraction() {
        var requests: [AppPermission] = []
        var urls: [URL] = []
        let model = PermissionsModel(check: { _ in false }, request: { requests.append($0) },
                                     openSettings: { urls.append($0); return true })
        model.authorize(.inputMonitoring)
        model.authorize(.accessibility)
        #expect(requests == [.inputMonitoring, .accessibility])
        #expect(urls.isEmpty)
        model.refresh()
        #expect(urls.isEmpty)
        #expect(model.requested == Set(AppPermission.allCases))
        // Only the separate, explicit manual fallback may open Settings.
        model.openSystemSettings(.inputMonitoring)
        model.openSystemSettings(.accessibility)
        #expect(urls.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
        #expect(model.granted.isEmpty)
        #expect(!model.canUseActions)
    }

    @Test func successfulRequestRefreshesBothPermissionsAndDoesNotOpenSettings() {
        var granted: Set<AppPermission> = []
        let model = PermissionsModel(check: { granted.contains($0) }, request: { _ in
            granted = Set(AppPermission.allCases)
        }, openSettings: { _ in
            Issue.record("No settings navigation is needed after a successful grant")
            return true
        })
        model.authorize(.accessibility)
        #expect(model.canUseActions)
        granted = [.inputMonitoring]
        model.refresh()
        #expect(!model.canUseActions)
        #expect(model.granted == [.inputMonitoring])
    }

    @Test func alreadyGrantedPermissionIsNotRequestedAgain() {
        let model = PermissionsModel(check: { _ in true }, request: { _ in
            Issue.record("Already granted access must not be requested again")
        }, openSettings: { _ in
            Issue.record("Already granted access must not open System Settings")
            return true
        })
        model.authorize(.inputMonitoring)
        #expect(model.canUseActions)
    }

    @Test func settingsOpenFailureProvidesManualInstructions() {
        let model = PermissionsModel(check: { _ in false }, request: { _ in }, openSettings: { _ in false })
        model.authorize(.accessibility)
        #expect(model.notice == nil)
        model.openSystemSettings(.accessibility)
        #expect(model.notice?.contains("系统设置 → 隐私与安全性 → 辅助功能") == true)
        #expect(!model.canUseActions)
    }

    // AppKit snapshot work occupies the main actor; run it separately so it
    // cannot delay cancellation in the subprocess timing tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMARTKEY_RENDER_PERMISSIONS"] == "1"))
    func renderGuidanceAndFinishOnlyOnceWhenClosed() throws {
        _ = NSApplication.shared
        for permission in AppPermission.allCases {
          for authorized in [false, true] {
            for dark in [false, true] {
                let model = PermissionsModel(check: { _ in authorized })
                model.refresh()
                let controller = PermissionWindowController(model: model, permissions: [permission])
                var completions = 0
                controller.onClose = { completions += 1 }
                let window = try #require(controller.window)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let view = try #require(window.contentView)
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                #expect(view.fittingSize.height <= view.bounds.height)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "smartKey-permissions-\(permission.rawValue)-\(authorized ? "granted" : "missing")\(dark ? "-dark" : "").png"
                try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name))
                #expect(completions == 0)
                controller.close()
                controller.close()
                #expect(completions == 1)
            }
          }
        }
        let model = PermissionsModel(check: { _ in false })
        let guide = PermissionWindowController(model: model)
        let destination = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        var transitionEvents: [String] = []
        guide.onOpenSettings = { destination.orderFrontRegardless(); transitionEvents.append("settings") }
        guide.onClose = {
            #expect(destination.isVisible)
            transitionEvents.append("guideClosed")
        }
        guide.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        guide.window?.orderFrontRegardless()
        guide.openSettings()
        #expect(transitionEvents == ["settings", "guideClosed"])
        destination.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SMARTKEY_RENDER_PERMISSIONS"] == "1"))
    func renderRestrictedSettingsAndActionPicker() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-permission-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "smartKey-permission-ui-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SettingsSection.scripts.rawValue, forKey: "smartKey.settings.section")
        var allowed = true
        let model = PermissionsModel(check: { $0 == .accessibility && allowed })
        let config = RuntimeConfiguration.load(url: directory.appendingPathComponent("smartKey.conf"))
        let coordinator = try ActionCoordinator(configuration: config, directory: directory, permissions: model)
        _ = try #require(coordinator.createScript())
        allowed = false
        coordinator.refresh()
        let pages: [(String, AnyView, NSSize)] = [
            ("settings", AnyView(SmartKeySettingsView(coordinator: coordinator).defaultAppStorage(defaults)), NSSize(width: 800, height: 640)),
            ("bindings", AnyView(BindingsSettingsView(coordinator: coordinator)), NSSize(width: 620, height: 640)),
            ("picker", AnyView(BindingEditor(coordinator: coordinator, slot: .singleClick)), NSSize(width: 440, height: 300)),
            ("scripts", AnyView(ScriptsSettingsView(coordinator: coordinator)), NSSize(width: 800, height: 640)),
        ]
        for (name, page, size) in pages {
            let view = NSHostingView(rootView: page.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("smartKey-restricted-\(name).png"))
            window.orderOut(nil)
        }
    }
}
