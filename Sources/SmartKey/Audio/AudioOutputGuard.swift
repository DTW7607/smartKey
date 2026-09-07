import Foundation

enum AudioOutputGuardDecision: Equatable {
    case emit
    case swallow
    case failed
}

/// Records the last non-jack default output and, when enabled, silently restores
/// it if HAL switches to the analog jack.
final class AudioOutputGuard {
    var setDefault: ((String) throws -> Void)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var restoreTimeout: TimeInterval = 3

    private(set) var isEnabled = false
    private(set) var lastLegalOutputUID: String?

    private var pendingRestoreUID: String?
    private var pendingDeadline: TimeInterval?
    private var restoreArmed = true

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            pendingRestoreUID = nil
            pendingDeadline = nil
        }
    }

    @discardableResult
    func handle(_ snapshot: SmartKeyAudioSnapshot) -> AudioOutputGuardDecision {
        if let uid = Self.legalDefaultUID(snapshot) {
            lastLegalOutputUID = uid
            restoreArmed = true
            pendingRestoreUID = nil
            pendingDeadline = nil
            return .emit
        }

        if pendingRestoreUID != nil, now() >= (pendingDeadline ?? .infinity) {
            pendingRestoreUID = nil
            pendingDeadline = nil
            restoreArmed = false
            return .failed
        }

        if pendingRestoreUID != nil, snapshot.isAnalogJackDefaultOutput {
            return .swallow
        }

        guard isEnabled, restoreArmed, snapshot.isAnalogJackDefaultOutput else {
            return .emit
        }

        guard let uid = lastLegalOutputUID, Self.isLegal(uid, in: snapshot) else {
            restoreArmed = false
            return .failed
        }

        pendingRestoreUID = uid
        pendingDeadline = now() + restoreTimeout
        do {
            try setDefault?(uid)
        } catch {
            pendingRestoreUID = nil
            pendingDeadline = nil
            restoreArmed = false
            return .failed
        }
        return .swallow
    }

    private static func legalDefaultUID(_ snapshot: SmartKeyAudioSnapshot) -> String? {
        snapshot.outputs.first { $0.uid == snapshot.defaultOutputUID && !$0.isAnalogJack }?.uid
    }

    private static func isLegal(_ uid: String, in snapshot: SmartKeyAudioSnapshot) -> Bool {
        snapshot.outputs.contains { $0.uid == uid && !$0.isAnalogJack }
    }
}
