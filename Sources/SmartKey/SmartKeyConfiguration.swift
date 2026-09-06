import Foundation

public struct SmartKeyEventKind: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let press = Self(rawValue: 1 << 0)
    public static let release = Self(rawValue: 1 << 1)
    public static let singleClick = Self(rawValue: 1 << 2)
    public static let doubleClick = Self(rawValue: 1 << 3)
    public static let longPress = Self(rawValue: 1 << 4)
    public static let jack = Self(rawValue: 1 << 5)

    public static let raw: Self = [.press, .release]
    public static let gestures: Self = [.singleClick, .doubleClick, .longPress]
    public static let all: Self = [.raw, .gestures, .jack]
}

public struct SmartKeyConfiguration: Equatable, Sendable {
    public var doubleClickMs: Int
    public var longPressMs: Int
    public var emitJackOnStart: Bool
    public var enabledEvents: SmartKeyEventKind

    public static let `default` = SmartKeyConfiguration()

    public var doubleClickGap: TimeInterval { TimeInterval(doubleClickMs) / 1000 }
    public var longPressDuration: TimeInterval { TimeInterval(longPressMs) / 1000 }

    public init(
        doubleClickMs: Int = 600,
        longPressMs: Int = 1300,
        emitJackOnStart: Bool = false,
        enabledEvents: SmartKeyEventKind = .all
    ) {
        self.doubleClickMs = doubleClickMs
        self.longPressMs = longPressMs
        self.emitJackOnStart = emitJackOnStart
        self.enabledEvents = enabledEvents
    }
}
