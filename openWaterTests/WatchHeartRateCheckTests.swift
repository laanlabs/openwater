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
}
