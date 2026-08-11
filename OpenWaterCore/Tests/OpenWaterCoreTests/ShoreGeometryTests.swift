import Foundation
import Testing
@testable import OpenWaterCore

/// The shore bearing and what it makes of directions — mostly wraparound
/// traps and the taper's edges.
@Suite("Shore geometry")
struct ShoreGeometryTests {

    /// A beach on a west-facing coast: sand at your back, Pacific ahead.
    let westFacing = ShoreGeometry(waterFacingDeg: 270)

    @Test("An easterly off the land is offshore, a westerly off the sea is onshore")
    func windRelations() {
        #expect(westFacing.windRelation(windFromDeg: 90) == .offshore)
        #expect(westFacing.windRelation(windFromDeg: 270) == .onshore)
        #expect(westFacing.windRelation(windFromDeg: 0) == .crossShore)
        #expect(westFacing.windRelation(windFromDeg: 180) == .crossShore)
    }

    @Test("The relation survives the wrap at north")
    func wraparound() {
        // Facing just west of north; wind from just east of south is the
        // reciprocal — straight offshore, however the degrees wrap.
        let northFacing = ShoreGeometry(waterFacingDeg: 350)
        #expect(northFacing.windRelation(windFromDeg: 170) == .offshore)
        #expect(northFacing.windRelation(windFromDeg: 355) == .onshore)
        #expect(northFacing.windRelation(windFromDeg: 10) == .onshore)
    }

    @Test("Swell from the facing pours in, swell from behind is blocked")
    func exposureEnds() {
        #expect(westFacing.exposure(swellFromDeg: 270) == 1)
        #expect(westFacing.exposure(swellFromDeg: 300) == 1)
        #expect(westFacing.exposure(swellFromDeg: 90) == 0)
    }

    @Test("The taper falls smoothly and monotonically outside the window")
    func taperMonotonic() {
        // 75° half-width at short period: window edge at 345/195. Walk the
        // taper from just inside to past its end.
        let inside = westFacing.exposure(swellFromDeg: 340, periodS: 6)
        let early = westFacing.exposure(swellFromDeg: 350, periodS: 6)
        let late = westFacing.exposure(swellFromDeg: 10, periodS: 6)
        let gone = westFacing.exposure(swellFromDeg: 40, periodS: 6)
        #expect(inside == 1)
        #expect(early < 1 && early > 0)
        #expect(late < early)
        #expect(gone == 0)
    }

    @Test("Long period widens the window, and never narrows it")
    func longPeriodWidens() {
        // 80° off the facing: outside the 75° window for chop, inside the
        // widened window for a 16 s groundswell.
        let chop = westFacing.exposure(swellFromDeg: 190, periodS: 6)
        let groundswell = westFacing.exposure(swellFromDeg: 190, periodS: 16)
        #expect(groundswell == 1)
        #expect(chop < groundswell)

        // Everywhere, longer period admits at least as much energy.
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            #expect(westFacing.exposure(swellFromDeg: degrees, periodS: 16)
                    >= westFacing.exposure(swellFromDeg: degrees, periodS: 6))
        }
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let geometry = ShoreGeometry(waterFacingDeg: 217.5, exposureHalfWidthDeg: 60)
        let decoded = try JSONDecoder().decode(
            ShoreGeometry.self, from: JSONEncoder().encode(geometry))
        #expect(decoded == geometry)
    }
}
