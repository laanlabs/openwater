import Testing
@testable import openWater

/// What Settings tells a rider after asking the watch about heart rate.
///
/// The check exists because the failure is invisible: HealthKit never reports
/// a denied *read*, so a rider whose first session's Health prompt was
/// declined just sees sessions arrive with no beat in them. The watch probes
/// its own store and sends back two facts; these are the four things they can
/// mean, and each has to lead somewhere a rider can actually go.
@MainActor
@Suite("Watch heart-rate check")
struct WatchHeartRateCheckTests {

    @Test("A watch that cannot do Health at all says so and stops")
    func unavailable() {
        let verdict = PhoneSyncClient.heartRateVerdict(
            from: ["available": false, "asked": false, "canRead": false])
        #expect(verdict.contains("cannot record heart rate"))
    }

    @Test("Never asked sends the rider to the watch, not to Settings")
    func neverAsked() {
        // The prompt only appears at the start of a session, so telling
        // somebody to go turning switches on would send them looking for one
        // that does not exist yet.
        let verdict = PhoneSyncClient.heartRateVerdict(
            from: ["available": true, "asked": false, "canRead": false])
        #expect(verdict.contains("has not asked"))
        #expect(verdict.contains("Start a session"))
    }

    @Test("A sample coming back is proof, and reads as good news")
    func granted() {
        let verdict = PhoneSyncClient.heartRateVerdict(
            from: ["available": true, "asked": true, "canRead": true])
        #expect(verdict.contains("Heart rate is on"))
    }

    @Test("Asked, and no sample, names the exact switch to turn on")
    func denied() {
        // The one case worth being pedantic about, twice over. A rider told
        // "permission is off" and not told where the switch is will look in
        // this app's settings, which is the one place it is not — and the
        // first version of this sent them to the Watch app's Privacy section,
        // which is the wrong place too. HealthKit's read permissions live in
        // the Health app, under the profile, and nowhere else.
        let verdict = PhoneSyncClient.heartRateVerdict(
            from: ["available": true, "asked": true, "canRead": false])
        #expect(verdict.contains("Health app"))
        #expect(verdict.contains("profile"))
        #expect(verdict.contains("Privacy ▸ Apps"))
        #expect(verdict.contains("openWater"))
        #expect(!verdict.contains("Watch app"))
    }

    @Test("A reply that says nothing is not read as good news")
    func emptyReply() {
        // An empty dictionary is what an older watch build answers with, and
        // silence must never come out as "heart rate is on".
        let verdict = PhoneSyncClient.heartRateVerdict(from: [:])
        #expect(!verdict.contains("Heart rate is on"))
    }

    // MARK: - The shape behind the sentence

    // The watch check sheet does more than print the verdict: it draws a tick
    // for one answer and a three-step walk-through to the Health app for
    // another, so it needs the answer's shape rather than its words. These pin
    // the mapping, and that the sentence is still derived from it — one source
    // of truth, so a reworded verdict can never disagree with the icon beside
    // it.

    @Test("Each reply maps to the state the sheet branches on")
    func states() {
        #expect(PhoneSyncClient.heartRateState(
            from: ["available": false, "asked": false, "canRead": false]) == .unavailable)
        #expect(PhoneSyncClient.heartRateState(
            from: ["available": true, "asked": false, "canRead": false]) == .notAsked)
        #expect(PhoneSyncClient.heartRateState(
            from: ["available": true, "asked": true, "canRead": true]) == .on)
        #expect(PhoneSyncClient.heartRateState(
            from: ["available": true, "asked": true, "canRead": false]) == .off)
        #expect(PhoneSyncClient.heartRateState(from: [:]) == .unavailable)
    }

    @Test("Only a real sample counts as good news")
    func onlyOnIsGood() {
        // What gates the green tick. `.notAsked` is the trap: nothing is
        // wrong yet, but nothing is working either, and a tick against it
        // would tell a rider their heartbeat is being recorded when no
        // session has ever asked for it.
        #expect(PhoneSyncClient.HeartRateState.on.isGood)
        #expect(!PhoneSyncClient.HeartRateState.notAsked.isGood)
        #expect(!PhoneSyncClient.HeartRateState.off.isGood)
        #expect(!PhoneSyncClient.HeartRateState.unavailable.isGood)
    }

    @Test("The sentence still comes from the state")
    func verdictFollowsState() {
        for reply in [["available": false], ["available": true, "asked": false],
                      ["available": true, "asked": true, "canRead": true],
                      ["available": true, "asked": true, "canRead": false]] {
            #expect(PhoneSyncClient.heartRateVerdict(from: reply)
                    == PhoneSyncClient.heartRateState(from: reply).message)
        }
    }
}
