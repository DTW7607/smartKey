import Foundation

enum AnalogJack {
    static let outputUID = "BuiltInHeadphoneOutputDevice"
    static let inputUIDs: Set<String> = [
        "BuiltInHeadphoneInputDevice",
        "BuiltInHeadsetInputDevice",
    ]
    static let transport: UInt32 = 0x626C_746E // 'bltn'

    static func isOutput(_ uid: String) -> Bool { uid == outputUID }
    static func isInput(_ uid: String) -> Bool { inputUIDs.contains(uid) }
    static func isJack(_ uid: String) -> Bool { isOutput(uid) || isInput(uid) }
}
