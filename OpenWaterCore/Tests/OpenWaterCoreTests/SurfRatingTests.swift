import Foundation
import Testing
@testable import OpenWaterCore

/// The opinion, held to its own rules: energy sets the base, wind is only
/// judged against a known shore, and not knowing the beach caps the score.
@Suite("Surf rating")
struct SurfRatingTests {

    let westShore = ShoreGeometry(waterFacingDeg: 270)

    @Test("Flat is zero, with the reason saying so")
    func flat() {
        let rating = SurfRating.rate(trains: [], shore: westShore,
                                     windKn: 5, windFromDeg: 90)
        #expect(rating.score == 0)
        #expect(rating.reasons == [.flat])
    }

    @Test("A big clean offshore day earns the top score")
    func firing() {
        let rating = SurfRating.rate(
            trains: [SwellTrain(heightM: 2.5, periodS: 15, directionFromDeg: 270)],
            shore: westShore, windKn: 8, windFromDeg: 90)
        #expect(rating.score == 5)
        #expect(rating.reasons.contains(.swell(heightM: 2.5, periodS: 15)))
        #expect(rating.reasons.contains(.wind(.offshore, kn: 8)))
    }

    @Test("The same sea blown out by 20 kn onshore scores low")
    func blownOut() {
        let rating = SurfRating.rate(
            trains: [SwellTrain(heightM: 2.5, periodS: 15, directionFromDeg: 270)],
            shore: westShore, windKn: 20, windFromDeg: 270)
        #expect(rating.score <= 2)
        #expect(rating.reasons.contains(.wind(.onshore, kn: 20)))
    }

    @Test("Without a shore bearing the score is capped at 3 and says so")
    func noShoreCap() {
        let rating = SurfRating.rate(
            trains: [SwellTrain(heightM: 2.5, periodS: 15, directionFromDeg: 270)],
            shore: nil, windKn: 8, windFromDeg: 90)
        #expect(rating.score == 3)
        #expect(rating.reasons.contains(.noShoreBearing))
        // And the wind is not scored at all against an unknown beach —
        // no wind reason should appear.
        #expect(!rating.reasons.contains { reason in
            if case .wind = reason { return true } else { return false }
        })
    }

    @Test("Swell the facing blocks rates as flat, not as surf")
    func blockedSwell() {
        // Two metres of groundswell arriving from due east — behind a
        // west-facing beach's back.
        let rating = SurfRating.rate(
            trains: [SwellTrain(heightM: 2, periodS: 14, directionFromDeg: 90)],
            shore: westShore, windKn: 5, windFromDeg: 90)
        #expect(rating.score == 0)
        #expect(rating.reasons.contains { reason in
            if case .exposureGated = reason { return true } else { return false }
        })
    }

    @Test("Short-period chop loses the point that height alone would earn")
    func shortPeriodPenalty() {
        let chop = SurfRating.rate(
            trains: [SwellTrain(heightM: 1.5, periodS: 5, directionFromDeg: 270)],
            shore: westShore, windKn: nil, windFromDeg: nil)
        let groundswell = SurfRating.rate(
            trains: [SwellTrain(heightM: 1.5, periodS: 12, directionFromDeg: 270)],
            shore: westShore, windKn: nil, windFromDeg: nil)
        #expect(chop.score < groundswell.score)
        #expect(chop.reasons.contains(.shortPeriod))
    }

    @Test("Glassy beats windy on the same swell")
    func glassyBonus() {
        let glassy = SurfRating.rate(
            trains: [SwellTrain(heightM: 1.2, periodS: 12, directionFromDeg: 270)],
            shore: westShore, windKn: 2, windFromDeg: 270)
        let onshore = SurfRating.rate(
            trains: [SwellTrain(heightM: 1.2, periodS: 12, directionFromDeg: 270)],
            shore: westShore, windKn: 14, windFromDeg: 270)
        #expect(glassy.score > onshore.score)
        #expect(glassy.reasons.contains(.glassy))
    }

    @Test("Reasons are never empty and every reason has words")
    func reasonsAlwaysSpeak() {
        let cases: [SurfRating] = [
            SurfRating.rate(trains: [], shore: nil, windKn: nil, windFromDeg: nil),
            SurfRating.rate(trains: [SwellTrain(heightM: 1, periodS: 10, directionFromDeg: 250)],
                            shore: westShore, windKn: 12, windFromDeg: 100),
            SurfRating.rate(trains: [SwellTrain(heightM: 3, periodS: 16, directionFromDeg: 280)],
                            shore: nil, windKn: nil, windFromDeg: nil),
        ]
        for rating in cases {
            #expect(!rating.reasons.isEmpty)
            for reason in rating.reasons {
                #expect(!reason.words.isEmpty)
            }
        }
    }
}
