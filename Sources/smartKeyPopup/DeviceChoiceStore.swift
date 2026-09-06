import Foundation

enum DeviceTypeChoice: String {
    case audioDevice
    case smartKey

    var title: String { self == .smartKey ? "智键" : "音频设备" }
}

protocol DeviceChoiceStoring: AnyObject {
    var lastChoice: DeviceTypeChoice { get set }
}

/// Separate user history from editable timing/layout configuration.
final class DeviceChoiceStore: DeviceChoiceStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = UserDefaults(suiteName: "local.smartKey") ?? .standard) {
        self.defaults = defaults
    }

    var lastChoice: DeviceTypeChoice {
        get {
            defaults.string(forKey: "smartKey.lastDeviceType")
                .flatMap(DeviceTypeChoice.init(rawValue:)) ?? .smartKey
        }
        set { defaults.set(newValue.rawValue, forKey: "smartKey.lastDeviceType") }
    }
}
