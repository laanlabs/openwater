import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Headline metrics")
struct HeadlineMetricsTests {

    let builder = TrackBuilder()

    // MARK: - The preference, which depends only on the sport

    @Test("Swell sports lead with glides, everything else leads with flight time")
    func preferenceBySport() {
        for sport in [Sport.downwindSUP, .sup, .prone] {
            #expect(HeadlineMetrics.preference(for: sport).first == .timeGliding,
                    "\(sport.rawValue) rides swell, so glides come first")
        }
        for sport in [Sport.wingfoil, .parawing, .windfoil, .kitefoil, .efoil, .tow] {
            #expect(HeadlineMetrics.preference(for: sport).first == .timeOnFoil,
                    "\(sport.rawValue) foils, so flight time comes first")
        }
    }

    @Test("Every sport can always fall back to average moving speed")
    func averageIsAlwaysLast() {
        for sport in Sport.allCases {
            let order = HeadlineMetrics.preference(for: sport)
            #expect(order.last == .averageMovingSpeed)
            #expect(Set(order).count == order.count, "no measure listed twice")
        }
    }

    // MARK: - The choice, which also depends on what the analysis found

    @Test("A wing session that flew leads with time on foil")
    func flyingSessionShowsFoilTime() {
        let track = builder.build(from: SyntheticTrack.wingSession())
        let summary = SessionAnalyzer(sport: .wingfoil).analyse(track)

        #expect(summary.foil.flightCount > 0, "precondition: this session flew")
        #expect(HeadlineMetrics.slot(for: .wingfoil, summary: summary) == .timeOnFoil)
    }

    @Test("A session with nothing detected falls back to average moving speed")
    func flatSessionShowsAverage() {
        // A steady paddle: no flights to find and no bumps to glide on.
        let track = builder.build(from: SyntheticTrack.constantSpeed(3, duration: 900))
        let summary = SessionAnalyzer(sport: .kayak).analyse(track)

        #expect(summary.foil.flightCount == 0)
        #expect(summary.downwind.glideCount == 0)
        #expect(HeadlineMetrics.slot(for: .kayak, summary: summary) == .averageMovingSpeed)
    }

    @Test("A downwinder that also tripped the flight detector still leads with glides")
    func swellSportPrefersGlidesOverFlights() {
        // Six pump-and-glide cycles: the shape the glide detector is built for.
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<6 {
            legs.append(.init(speed: 5, heading: 200, duration: 6))
            legs.append(.init(speed: 9, heading: 200, duration: 12, transition: 2))
        }
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let summary = SessionAnalyzer(sport: .downwindSUP).analyse(track)

        #expect(summary.downwind.glideCount > 0, "precondition: this session glided")
        #expect(HeadlineMetrics.slot(for: .downwindSUP, summary: summary) == .timeGliding,
                "glides win for a swell sport even when flights were also detected")
    }

    @Test("A foiling sport with glides but no flights borrows the glide tile")
    func fallsThroughToTheNextAvailableMeasure() {
        var legs: [SyntheticTrack.Leg] = []
        for _ in 0..<6 {
            legs.append(.init(speed: 5, heading: 200, duration: 6))
            legs.append(.init(speed: 9, heading: 200, duration: 12, transition: 2))
        }
        let track = builder.build(from: SyntheticTrack.generate(legs: legs))
        let summary = SessionAnalyzer(sport: .downwindSUP).analyse(track)

        // Same data, asked as a wing session: foil time is preferred but the
        // preference only counts when the measure exists.
        let expected: HeadlineMetrics.Slot =
            summary.foil.flightCount > 0 ? .timeOnFoil
            : summary.downwind.glideCount > 0 ? .timeGliding
            : .averageMovingSpeed
        #expect(HeadlineMetrics.slot(for: .wingfoil, summary: summary) == expected)
    }

    // MARK: - Titles

    @Test("Every slot has a label")
    func everySlotIsNamed() {
        for slot in HeadlineMetrics.Slot.allCases {
            #expect(!slot.title.isEmpty)
        }
    }
}
