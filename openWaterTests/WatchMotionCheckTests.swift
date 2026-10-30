import Testing
@testable import openWater

/// What the phone tells a rider after asking the watch about its altimeter.
///
/// A wingfoil session in chop came back with "no jumps recorded" from a rider
/// filmed jumping; Motion & Fitness was off on the watch. These are the
/// answers the watch can give and where each one sends the rider.
@MainActor
@Suite("Watch Motion & Fitness check")
struct WatchMotionCheckTests {

    @Test("Granted reads as good news")
    func granted() {
        let state = PhoneSyncClient.motionState(from: ["available": true, "motion": "authorized"])
        #expect(state == .on)
        #expect(state.isGood)
    }

    @Test("Denied and restricted both name the switch")
    func denied() {
        for status in ["denied", "restricted"] {
            let state = PhoneSyncClient.motionState(from: ["available": true, "motion": status])
            #expect(state == .off)
            #expect(state.message.contains("Motion & Fitness"))
            #expect(state.message.contains("Fitness Tracking"))
        }
    }

    @Test("Never asked sends the rider to the watch")
    func notAsked() {
        let state = PhoneSyncClient.motionState(from: ["available": true, "motion": "notDetermined"])
        #expect(state == .notAsked)
        #expect(state.message.contains("Open openWater on your watch"))
    }

    @Test("A watch with no barometer is not told to flip a switch")
    func unavailable() {
        let state = PhoneSyncClient.motionState(from: ["available": false, "motion": "authorized"])
        #expect(state == .unavailable)
    }

    @Test("An older watch app's empty reply is not read as off")
    func olderWatch() {
        let state = PhoneSyncClient.motionState(from: [:])
        #expect(state == .unknown)
        #expect(!state.isGood)
    }
}
