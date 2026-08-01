import Foundation
import Testing
@testable import OpenWaterCore

/// Per-sport receiver settings, and the accuracy gate the live screens use.
///
/// These exist because of a bug that produced no error and no crash: every
/// sport shared one 12-metre accuracy limit, and `LiveAnalyzer` applied it to
/// the live display. Any fix worse than that was discarded silently, so on a
/// cold receiver — or a wrist under a wetsuit sleeve — the speed simply stopped
/// changing. It looked exactly like a slow GPS, which is the one explanation it
/// was not. The rules below are the ones that keep that from coming back.
@Suite("Location profiles")
struct LocationProfileTests {

    @Test("The live gate is looser than the record-grade one for every sport")
    func liveGateIsLooserEverywhere() {
        for sport in Sport.allCases {
            let t = sport.thresholds
            #expect(t.liveAccuracyLimit > t.maxHorizontalAccuracy,
                    "\(sport) would freeze its live display before the fix is bad enough to drop")
        }
    }

    @Test("The live gate stays tight enough to be worth having")
    func liveGateIsNotUnbounded() {
        // Loose is the point, but a 200-metre fix on the live screen is not a
        // noisy number, it is a wrong one.
        for sport in Sport.allCases {
            #expect(sport.thresholds.liveAccuracyLimit <= 60, "\(sport)")
        }
    }

    @Test("Everything that flies asks the receiver for navigation-grade fixes")
    func foilingSportsGetNavigationAccuracy() {
        // The runs are twenty seconds long and the peak lives in a two-second
        // window; this is also the mode that keeps Doppler speed flowing, which
        // every speed number in the app is built on.
        let flying: [Sport] = [.wingfoil, .parawing, .windfoil, .kitefoil,
                               .downwindSUP, .prone, .efoil, .tow]
        for sport in flying {
            #expect(sport.locationProfile.accuracy == .navigation, "\(sport)")
            #expect(sport.thresholds.liveAccuracyLimit >= 50, "\(sport)")
        }
    }

    @Test("No sport sets a distance filter")
    func noSportFiltersByDistance() {
        // A distance filter drops fixes between deliveries, which destroys the
        // even sampling every windowed metric assumes — and a rider sitting on
        // the board would stop being recorded at all.
        for sport in Sport.allCases {
            #expect(sport.locationProfile.distanceFilter == nil, "\(sport)")
        }
    }

    @Test("A cold receiver still moves the live speed")
    func softFixesStillDriveTheLiveDisplay() {
        // 20 m is worse than anything the saved session will accept and better
        // than the live screen's limit: the number on the wrist should move.
        var points = SyntheticTrack.constantSpeed(11, duration: 40, heading: 90)
        for i in points.indices { points[i].horizontalAccuracy = 20 }

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        #expect(analyzer.metrics.currentSpeed > 8)
        #expect(analyzer.metrics.distance > 0)
    }

    @Test("Genuinely useless fixes are still refused")
    func hopelessFixesAreRejected() {
        var points = SyntheticTrack.constantSpeed(11, duration: 40, heading: 90)
        for i in points.indices { points[i].horizontalAccuracy = 400 }

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        for point in points { analyzer.add(point) }

        #expect(analyzer.metrics.currentSpeed == 0)
        // The accuracy still reaches the screen, so the rider sees *why*
        // nothing is moving rather than staring at a frozen display.
        #expect(analyzer.metrics.horizontalAccuracy == 400)
    }

    @Test("The delivery interval is reported once there is something to measure")
    func reportsFixInterval() {
        let points = SyntheticTrack.constantSpeed(9, duration: 20, heading: 90)

        let analyzer = LiveAnalyzer(sport: .wingfoil)
        analyzer.add(points[0])
        #expect(analyzer.metrics.fixInterval == nil, "one fix cannot have an interval")

        for point in points.dropFirst() { analyzer.add(point) }
        #expect(analyzer.metrics.fixInterval == 1)
    }
}
