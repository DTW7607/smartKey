import Foundation
import Testing
@testable import SmartKey

private let headphones = SmartKeyAudioDevice(uid: "jack", name: "外置耳机", transport: .builtIn, isAnalogJack: true)
private let speakers = SmartKeyAudioDevice(uid: "speakers", name: "MacBook Air 扬声器", transport: .builtIn, isAnalogJack: false)
private let bluetooth = SmartKeyAudioDevice(uid: "bluetooth", name: "AirPods Pro", transport: .bluetooth, isAnalogJack: false)

private func snap(_ devices: [SmartKeyAudioDevice], default uid: String?) -> SmartKeyAudioSnapshot {
    SmartKeyAudioSnapshot(outputs: devices, inputs: [], defaultOutputUID: uid, defaultInputUID: nil)
}

@Suite
struct AudioOutputGuardTests {
    @Test func analogJackDefaultOutputUsesOutputDeviceFlag() {
        let jackDefault = snap([headphones, speakers], default: "jack")
        #expect(jackDefault.isAnalogJackDefaultOutput)
        let speakerDefault = snap([headphones, speakers], default: "speakers")
        #expect(!speakerDefault.isAnalogJackDefaultOutput)
        let inputAsDefault = SmartKeyAudioSnapshot(
            outputs: [speakers],
            inputs: [SmartKeyAudioDevice(uid: AnalogJack.inputUIDs.first!, name: "headset",
                                         transport: .builtIn, isAnalogJack: true)],
            defaultOutputUID: AnalogJack.inputUIDs.first!,
            defaultInputUID: nil
        )
        #expect(!inputAsDefault.isAnalogJackDefaultOutput)
    }

    @Test func disabledGuardRecordsLastLegalButDoesNotRestore() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        #expect(outputGuard.handle(snap([headphones, speakers], default: "speakers")) == .emit)
        #expect(outputGuard.lastLegalOutputUID == "speakers")
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .emit)
        #expect(writes.isEmpty)
        #expect(outputGuard.lastLegalOutputUID == "speakers")
    }

    @Test func enabledGuardRestoresLastLegalAndSwallowsJack() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, speakers, bluetooth], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers, bluetooth], default: "jack")) == .swallow)
        #expect(writes == ["speakers"])
        #expect(outputGuard.handle(snap([headphones, speakers, bluetooth], default: "speakers")) == .emit)
        #expect(writes == ["speakers"])
    }

    @Test func userSwitchToAnotherLegalDeviceUpdatesLastLegal() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, speakers, bluetooth], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers, bluetooth], default: "bluetooth")) == .emit)
        #expect(outputGuard.lastLegalOutputUID == "bluetooth")
        #expect(writes.isEmpty)
        #expect(outputGuard.handle(snap([headphones, speakers, bluetooth], default: "jack")) == .swallow)
        #expect(writes == ["bluetooth"])
    }

    @Test func missingLastLegalFailsAndDoesNotRetryUntilLegalDefaultReturns() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        var failures = 0
        outputGuard.setDefault = { writes.append($0) }
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones], default: "jack")) == .failed)
        failures += 1
        #expect(outputGuard.handle(snap([headphones], default: "jack")) == .emit)
        #expect(writes.isEmpty)
        #expect(failures == 1)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "speakers")) == .emit)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .swallow)
        #expect(writes == ["speakers"])
    }

    @Test func lastLegalNotInOutputsFails() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, bluetooth], default: "bluetooth"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones], default: "jack")) == .failed)
        #expect(writes.isEmpty)
    }

    @Test func setDefaultErrorFailsAndDisarms() {
        let outputGuard = AudioOutputGuard()
        outputGuard.setDefault = { _ in throw SmartKeyAudioError.notSelectable("speakers") }
        _ = outputGuard.handle(snap([headphones, speakers], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .failed)
        outputGuard.setDefault = { _ in }
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .emit)
    }

    @Test func pendingJackSnapshotDoesNotWriteTwice() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, speakers], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .swallow)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .swallow)
        #expect(writes == ["speakers"])
    }

    @Test func pendingRestoreTimesOut() {
        var clock: TimeInterval = 10
        let outputGuard = AudioOutputGuard()
        outputGuard.now = { clock }
        outputGuard.restoreTimeout = 3
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, speakers], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .swallow)
        clock = 13
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .failed)
        #expect(writes == ["speakers"])
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .emit)
    }

    @Test func disablingClearsPendingAndStopsRestore() {
        let outputGuard = AudioOutputGuard()
        var writes: [String] = []
        outputGuard.setDefault = { writes.append($0) }
        _ = outputGuard.handle(snap([headphones, speakers], default: "speakers"))
        outputGuard.setEnabled(true)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .swallow)
        outputGuard.setEnabled(false)
        #expect(outputGuard.handle(snap([headphones, speakers], default: "jack")) == .emit)
        #expect(writes == ["speakers"])
        #expect(outputGuard.lastLegalOutputUID == "speakers")
    }
}
