import Foundation
import Testing
@testable import OpenWaterCore

/// A rider's own thresholds, and whether they reach the numbers.
///
/// The point of this feature is that the defaults are averages of boards,
/// wings and body weights, and a rider whose foil lifts three knots later than
/// average has a "time on foil" that is about openWater rather than about them.
/// So what matters is not that the setting stores — it is that every detector
/// carrying its own copy of the thresholds gets the changed one. Two of them
/// build from `sport` directly and were missing it.
@Suite("Sport overrides")
struct SportOverrideTests {

    private func session(peak: Double = 11) -> Track {
        // Rises and falls through the takeoff band, so where the line is drawn
        // genuinely changes the answer.
        var points = SyntheticTrack.constantSpeed(peak, duration: 600, heading: 90)
        for i in points.indices {
            let phase = sin(Double(i) / 45)
            points[i].speed = max(0.4, peak * (0.55 + 0.45 * phase))
            points[i].horizontalAccuracy = 5
            points[i].verticalAccelSD = 0.8
        }
        return TrackBuilder(options: .forSport(.wingfoil)).build(from: points)
    }

    @Test("Nothing set changes nothing")
    func emptyIsANoOp() {
        let base = Sport.wingfoil.thresholds
        #expect(SportThresholds.Overrides().applied(to: base) == base)
        #expect(SportThresholds.Overrides().isEmpty)
    }

    @Test("Only the fields set are changed")
    func partialOverrideKeepsTheRest() {
        let base = Sport.wingfoil.thresholds
        let applied = SportThresholds.Overrides(foilTakeoffSpeed: 7).applied(to: base)
        #expect(applied.foilTakeoffSpeed == 7)
        #expect(applied.movingSpeed == base.movingSpeed)
        #expect(applied.maneuverHeadingChange == base.maneuverHeadingChange)
    }

    @Test("A raised takeoff speed reduces time on foil")
    func takeoffSpeedReachesTheFoilDetector() {
        let track = session()
        let low = SessionAnalyzer(configuration: .init(
            sport: .wingfoil, overrides: .init(foilTakeoffSpeed: 4)
        )).analyse(track)
        let high = SessionAnalyzer(configuration: .init(
            sport: .wingfoil, overrides: .init(foilTakeoffSpeed: 9)
        )).analyse(track)
        #expect(high.foil.timeOnFoil < low.foil.timeOnFoil,
                "\(Int(high.foil.timeOnFoil)) s against \(Int(low.foil.timeOnFoil)) s")
    }

    @Test("A raised moving speed reduces moving time")
    func movingSpeedReachesTheClock() {
        let track = session()
        let low = SessionAnalyzer(configuration: .init(
            sport: .wingfoil, overrides: .init(movingSpeed: 0.5)
        )).analyse(track)
        let high = SessionAnalyzer(configuration: .init(
            sport: .wingfoil, overrides: .init(movingSpeed: 7)
        )).analyse(track)
        #expect(high.movingTime < low.movingTime)
        // And the average that divides by it moves the other way.
        #expect(high.averageMovingSpeed > low.averageMovingSpeed)
    }

    @Test("A per-session takeoff speed still beats the per-sport one")
    func sessionOverrideWins() {
        // The sport setting is a default for every session; the one on a
        // session is a statement about that session, and has to win.
        let track = session()
        let summary = SessionAnalyzer(configuration: .init(
            sport: .wingfoil,
            foilTakeoffSpeed: 4,
            overrides: .init(foilTakeoffSpeed: 9)
        )).analyse(track)
        let sportOnly = SessionAnalyzer(configuration: .init(
            sport: .wingfoil, overrides: .init(foilTakeoffSpeed: 9)
        )).analyse(track)
        #expect(summary.foil.timeOnFoil > sportOnly.foil.timeOnFoil)
    }

    @Test("Overrides survive a round trip through the settings store")
    func codable() throws {
        let stored: [Sport: SportThresholds.Overrides] = [
            .wingfoil: .init(foilTakeoffSpeed: 6.5),
            .kayak: .init(movingSpeed: 0.4),
        ]
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode([Sport: SportThresholds.Overrides].self, from: data)
        #expect(back == stored)
    }
}
