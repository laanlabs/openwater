import Foundation
import Testing
@testable import OpenWaterCore

/// What happens to the distance across a hole in the recording.
///
/// Written from a session recorded side by side in openWater and Waterspeed.
/// Both files show the same thing: a receiver that goes quiet for thirty to
/// three hundred seconds at a time while the rider drifts — thirty-nine such
/// gaps in a hundred minutes, about forty-two minutes in total. Refusing to
/// bridge them cost twelve percent of the distance and put us a whole nautical
/// mile behind the other app on the same afternoon.
///
/// The rider had not gone anywhere unrecorded. The implied speed across those
/// gaps was about a knot, so the straight line was very nearly the truth. What
/// still has to be refused is the gap you get by driving home with the app
/// running, and that is refused for the speed it would need rather than for
/// how long it lasted.
@Suite("Gap bridging")
struct GapBridgingTests {

    /// A track with a hole punched in it: `before` seconds of riding, a gap of
    /// `gap` seconds during which the rider moves at `driftSpeed`, then more
    /// riding.
    private func track(gap: TimeInterval, driftSpeed: Double) -> [TrackPoint] {
        var points = SyntheticTrack.constantSpeed(9, duration: 120, heading: 90)
        guard let last = points.last else { return points }

        // Where the rider ends up after the gap, having moved at `driftSpeed`.
        let metres = driftSpeed * gap
        let resumeAt = last.timestamp.addingTimeInterval(gap)
        let degreesEast = metres / (111_320 * cos(last.latitude * .pi / 180))

        var resumed = SyntheticTrack.constantSpeed(9, duration: 120, heading: 90)
        // Captured before the loop: reading element zero while rewriting the
        // array shifts every point by a different amount.
        let origin = resumed[0]
        let longitudeShift = degreesEast + (last.longitude - origin.longitude)
        for i in resumed.indices {
            let offset = resumed[i].timestamp.timeIntervalSince(origin.timestamp)
            resumed[i].timestamp = resumeAt.addingTimeInterval(offset)
            resumed[i].latitude = last.latitude
            resumed[i].longitude += longitudeShift
        }
        points += resumed
        return points
    }

    private func distance(_ points: [TrackPoint]) -> Double {
        TrackBuilder(options: .forSport(.wingfoil)).build(from: points).totalDistance
    }

    @Test("A quiet receiver over a drifting rider is bridged")
    func drifting() {
        // Ninety seconds at a knot: half a cable of real movement, and the
        // straight line across it is almost exactly what happened.
        let bridged = distance(track(gap: 90, driftSpeed: 0.5))
        let riding = distance(SyntheticTrack.constantSpeed(9, duration: 240, heading: 90))
        #expect(bridged > riding * 0.9,
                "\(Int(bridged)) m against \(Int(riding)) m of riding alone — the gap was dropped")
    }

    @Test("Gaps of several minutes are still bridged")
    func minutesLong() {
        // The measured session had gaps up to three hundred seconds. Thirty
        // was the old limit and it is what made us a nautical mile short.
        for gap in [45.0, 120.0, 300.0] {
            let d = distance(track(gap: gap, driftSpeed: 0.5))
            #expect(d > 2000, "a \(Int(gap)) s gap left only \(Int(d)) m")
        }
    }

    @Test("A drive home is not bridged")
    func impossibleSpeedIsRefused() {
        // Twenty kilometres in five minutes is 130 knots. Nothing on the water
        // does that, so the leg contributes nothing rather than inventing the
        // distance.
        let driving = distance(track(gap: 300, driftSpeed: 66))
        let riding = distance(SyntheticTrack.constantSpeed(9, duration: 240, heading: 90))
        #expect(driving < riding * 1.1,
                "\(Int(driving)) m — the drive was counted as sailing")
    }

    @Test("A gap longer than any plausible hole is not bridged")
    func absurdlyLongGapIsRefused() {
        // An hour is not a receiver going quiet; it is a session somebody
        // forgot to stop.
        let d = distance(track(gap: 3600, driftSpeed: 0.5))
        let riding = distance(SyntheticTrack.constantSpeed(9, duration: 240, heading: 90))
        #expect(d < riding * 1.1, "\(Int(d)) m — an hour-long hole was bridged")
    }

    @Test("An unbroken track is unaffected")
    func cleanTrackUnchanged() {
        let points = SyntheticTrack.constantSpeed(9, duration: 600, heading: 90)
        let built = TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
        // 9 m/s for 600 s is 5.4 km, and every leg is a second long.
        #expect(abs(built.totalDistance - 5400) < 100,
                "\(Int(built.totalDistance)) m, expected about 5400")
    }
}
