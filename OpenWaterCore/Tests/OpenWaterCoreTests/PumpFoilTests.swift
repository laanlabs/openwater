import Foundation
import Testing
@testable import OpenWaterCore

@Suite("Pump foil")
struct PumpFoilTests {

    @Test("Pump foil is a foiling sport with a pump rate and no wind")
    func shape() {
        let sport = Sport.pumpFoil
        #expect(sport.isFoiling)
        #expect(sport.hasCadence)
        #expect(!sport.isWindPowered)
        #expect(!sport.paddlesIntoWaves)
        #expect(Sport.recordable.contains(sport))
    }

    @Test("Pumped flight starts on speed alone")
    func pumpingDoesNotVetoFlight() {
        // The ride is all pump. A detector waiting for a smooth second would
        // never start a flight.
        #expect(!FoilDetector.forSport(.pumpFoil).motionVetoesFlight)
        #expect(FoilDetector.forSport(.wingfoil).motionVetoesFlight)
    }

    @Test("Takeoff sits under pumped cruising speed")
    func takeoffSpeed() {
        let t = Sport.pumpFoil.thresholds
        #expect(t.foilTakeoffSpeed < 3.5)
        #expect(t.foilTakeoffSpeed > t.movingSpeed)
    }

    @Test("A sport this build does not know decodes as other")
    func unknownSportDecodes() throws {
        let decoded = try JSONDecoder().decode([Sport].self, from: Data(#"["pumpFoil","hydroSurf"]"#.utf8))
        #expect(decoded == [.pumpFoil, .other])
    }

    @Test("Known sports round-trip")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(Sport.allCases)
        #expect(try JSONDecoder().decode([Sport].self, from: data) == Sport.allCases)
    }
}
