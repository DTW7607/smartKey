import Foundation

public enum SmartKeyButtonPhase: Sendable, Equatable {
    case pressed
    case released
}

public enum SmartKeyGesture: Sendable, Equatable {
    case singleClick
    case doubleClick
    case longPress
}

public struct SmartKeyGestureEvent: Sendable, Equatable {
    public let gesture: SmartKeyGesture
    public let count: Int
}

public enum SmartKeySeizeStatus: Sendable, Equatable {
    case idle
    case waiting
    case seized
    case failed
}

public enum SmartKeyAudioTransport: Sendable, Equatable {
    case builtIn
    case bluetooth
    case usb
    case displayPort
    case hdmi
    case airPlay
    case aggregate
    case virtual
    case other
}

public struct SmartKeyAudioDevice: Equatable, Sendable {
    public let uid: String
    public let name: String
    public let transport: SmartKeyAudioTransport
    public let isAnalogJack: Bool
}

public struct SmartKeyAudioSnapshot: Equatable, Sendable {
    public let outputs: [SmartKeyAudioDevice]
    public let inputs: [SmartKeyAudioDevice]
    public let defaultOutputUID: String?
    public let defaultInputUID: String?

    public var isAnalogJackDefaultOutput: Bool {
        defaultOutputUID.map { AnalogJack.isJack($0) } ?? false
    }

    public var isAnalogJackDefaultInput: Bool {
        defaultInputUID.map { AnalogJack.isJack($0) } ?? false
    }

    static let empty = SmartKeyAudioSnapshot(
        outputs: [],
        inputs: [],
        defaultOutputUID: nil,
        defaultInputUID: nil
    )
}

public enum SmartKeyAudioError: Error, CustomStringConvertible {
    case unknownUID(String)
    case notSelectable(String)
    case hardware(OSStatus)

    public var description: String {
        switch self {
        case let .unknownUID(uid): return "未知设备: \(uid)"
        case let .notSelectable(uid): return "不可设为默认设备: \(uid)"
        case let .hardware(status): return "音频硬件错误: \(status)"
        }
    }
}
