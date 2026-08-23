import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Synced preference")
struct SyncedPreferenceTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A newer change from the other device is taken")
    func newerWins() {
        #expect(SyncedPreference.accepts(incoming: now, over: now - 60))
    }

    @Test("A change queued before the local one is ignored")
    func staleIsIgnored() {
        // The phone's context was queued an hour ago and delivered now; the
        // rider changed it on the wrist in between.
        #expect(!SyncedPreference.accepts(incoming: now - 3600, over: now))
    }

    @Test("A tie goes to the device holding the value")
    func tieGoesLocal() {
        #expect(!SyncedPreference.accepts(incoming: now, over: now))
    }

    @Test("A device that never set it takes the first push")
    func firstPushWins() {
        #expect(SyncedPreference.accepts(incoming: now, over: .distantPast))
    }
}
