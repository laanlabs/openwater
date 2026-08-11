import Foundation
import Testing
@testable import OpenWaterCore

/// The conversions every surf screen must agree on — mostly the classic
/// swell-arithmetic traps: heights adding linearly, short chop out-voting
/// long swell, directions averaging across north the long way round.
@Suite("Swell math")
struct SwellMathTests {

    @Test("Energies add, heights do not: two 1 m trains make a 1.41 m sea")
    func rootSumSquare() {
        let trains = [SwellTrain(heightM: 1), SwellTrain(heightM: 1)]
        #expect(abs(SwellMath.combinedHeight(trains) - 2.0.squareRoot()) < 1e-9)
    }

    @Test("A single train passes through unchanged, and no trains make no sea")
    func degenerateCombinations() {
        #expect(SwellMath.combinedHeight([SwellTrain(heightM: 1.3)]) == 1.3)
        #expect(SwellMath.combinedHeight([]) == 0)
    }

    @Test("A metre at fifteen seconds outworks a metre and a half at six")
    func longPeriodCarriesMoreEnergy() {
        let groundswell = SwellTrain(heightM: 1.0, periodS: 15)
        let windSwell = SwellTrain(heightM: 1.5, periodS: 6)
        #expect(SwellMath.energy(groundswell) > SwellMath.energy(windSwell))
    }

    @Test("An unknown period counts as short, never as a bonus")
    func unknownPeriodIsConservative() {
        let known = SwellTrain(heightM: 1, periodS: SwellMath.assumedPeriodS)
        let unknown = SwellTrain(heightM: 1, periodS: nil)
        #expect(SwellMath.energy(unknown) == SwellMath.energy(known))
    }

    @Test("Dominant direction crosses north the short way")
    func dominantDirectionAcrossNorth() {
        let trains = [
            SwellTrain(heightM: 1, periodS: 10, directionFromDeg: 350),
            SwellTrain(heightM: 1, periodS: 10, directionFromDeg: 10),
        ]
        let direction = try! #require(SwellMath.dominantDirection(trains))
        #expect(Geo.angleSeparation(direction, 0) < 0.5)
    }

    @Test("The groundswell out-votes the chop about where the sea comes from")
    func energyWeightedDirection() {
        let trains = [
            SwellTrain(heightM: 2, periodS: 14, directionFromDeg: 270),
            SwellTrain(heightM: 0.5, periodS: 4, directionFromDeg: 0),
        ]
        let direction = try! #require(SwellMath.dominantDirection(trains))
        #expect(Geo.angleSeparation(direction, 270) < 5)
    }

    @Test("Directionless trains have no dominant direction")
    func noDirectionIsNil() {
        #expect(SwellMath.dominantDirection([SwellTrain(heightM: 1)]) == nil)
        #expect(SwellMath.dominantDirection([]) == nil)
    }

    @Test("Face heights grow with the offshore height")
    func faceRangeMonotonicInHeight() {
        let small = SwellMath.faceHeightRange(offshoreHs: 0.5, periodS: 8)
        let large = SwellMath.faceHeightRange(offshoreHs: 2.0, periodS: 8)
        #expect(large.lowerBound > small.lowerBound)
        #expect(large.upperBound > small.upperBound)
    }

    @Test("A longer period never shrinks the range, and tops out at 1.5×")
    func faceRangeWidensWithPeriod() {
        let short = SwellMath.faceHeightRange(offshoreHs: 1, periodS: 8)
        let long = SwellMath.faceHeightRange(offshoreHs: 1, periodS: 16)
        let longer = SwellMath.faceHeightRange(offshoreHs: 1, periodS: 22)
        #expect(long.upperBound > short.upperBound)
        #expect(abs(long.upperBound - 1.5) < 1e-9)
        #expect(longer.upperBound == long.upperBound)
        #expect(long.lowerBound == short.lowerBound)
    }

    @Test("Flat is flat: zero offshore height makes a zero range")
    func flatSea() {
        #expect(SwellMath.faceHeightRange(offshoreHs: 0, periodS: 12) == 0...0)
        #expect(SwellMath.faceHeightRange(offshoreHs: -1, periodS: nil) == 0...0)
    }
}
