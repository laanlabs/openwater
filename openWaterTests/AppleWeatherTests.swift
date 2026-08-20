import OpenWaterCore
import XCTest
@testable import openWater

/// The two pieces of Apple's weather service the conditions sheet reasons over.
///
/// WeatherKit answers with objects rather than bytes, so there is no wire
/// format to pin the way the Open-Meteo and NOAA parsers are pinned. The seam
/// is one step further in: the pure functions that turn already-extracted
/// values into the sentence a rider reads. Those carry all the judgement —
/// what counts as rain starting, how long a gap has to be before it is an end,
/// which forecast day belongs against which historical average — and every one
/// of those calls is a decision that can be wrong in a way nobody would notice
/// on screen.
final class AppleWeatherTests: XCTestCase {

    // MARK: - The minute nowcast

    private let start = Date(timeIntervalSince1970: 1_755_400_000)

    /// A run of minutes from `start`, one per entry, wet where the entry is
    /// non-nil. The value is the rate in mm/h.
    private func minutes(_ rates: [Double?], chance: Double = 0.9,
                         isRadar: Bool = true) -> [MinuteRain.Minute] {
        rates.enumerated().map { index, rate in
            MinuteRain.Minute(
                at: start.addingTimeInterval(Double(index) * 60),
                chance: rate == nil ? 0 : chance,
                intensityMmH: rate ?? 0,
                kind: rate == nil ? nil : .rain,
                isRadar: isRadar
            )
        }
    }

    func testEmptyWindowHasNoSummary() {
        XCTAssertNil(MinuteRain.summarise([], now: start))
    }

    /// Sixty dry minutes is the common case, and the one the card collapses to
    /// a single line — so `.dry` has to survive the round trip intact.
    func testDryHour() {
        let summary = MinuteRain.summarise(minutes(Array(repeating: nil, count: 60)), now: start)
        XCTAssertEqual(summary?.change, .dry)
        XCTAssertEqual(summary?.wetMinutes, 0)
        XCTAssertEqual(summary?.totalMinutes, 60)
        XCTAssertTrue(summary?.isDry == true)
        XCTAssertNil(summary?.detail)
        XCTAssertEqual(summary?.headline, "No rain in the next hour")
    }

    /// The headline case. Dry now, rain from minute twelve — and the answer is
    /// twelve, not eleven or thirteen, because the whole point of this card is
    /// that it names a minute.
    func testRainStartingCountsMinutesFromNow() {
        var rates = [Double?](repeating: nil, count: 60)
        for index in 12..<40 { rates[index] = 1.2 }
        let summary = MinuteRain.summarise(minutes(rates), now: start)
        XCTAssertEqual(summary?.change, .starting(minutesAway: 12))
        XCTAssertEqual(summary?.headline, "Rain starting in 12 min")
        XCTAssertEqual(summary?.wetMinutes, 28)
        XCTAssertEqual(summary?.band, "Light")
    }

    /// Radar flickers. One isolated wet minute is not a shower, and announcing
    /// it would have this card crying wolf on every hazy afternoon.
    func testSingleFlickeringMinuteIsNotRainStarting() {
        var rates = [Double?](repeating: nil, count: 60)
        rates[20] = 0.4
        XCTAssertEqual(MinuteRain.summarise(minutes(rates), now: start)?.change, .dry)
    }

    /// Falling now and easing off. The number is how much longer it lasts,
    /// which is what a rider waiting under a tree actually wants.
    func testRainStoppingReportsHowMuchLonger() {
        var rates = [Double?](repeating: nil, count: 60)
        for index in 0..<18 { rates[index] = 3.0 }
        let summary = MinuteRain.summarise(minutes(rates), now: start)
        XCTAssertEqual(summary?.change, .stopping(minutesAway: 18))
        XCTAssertEqual(summary?.headline, "Rain for another 18 min")
        XCTAssertEqual(summary?.band, "Moderate")
    }

    /// A two-minute gap inside a shower is a lull, not an end. Called as
    /// stopping, this would promise a rider a window that closes on them.
    func testShortGapDoesNotCountAsStopping() {
        var rates = [Double?](repeating: 2.0, count: 60)
        rates[20] = nil
        rates[21] = nil
        XCTAssertEqual(MinuteRain.summarise(minutes(rates), now: start)?.change, .throughout)
    }

    /// A gap that holds for ten minutes is an end, and gets reported as one.
    func testLongGapCountsAsStopping() {
        var rates = [Double?](repeating: 2.0, count: 60)
        for index in 20..<34 { rates[index] = nil }
        XCTAssertEqual(MinuteRain.summarise(minutes(rates), now: start)?.change,
                       .stopping(minutesAway: 20))
    }

    func testRainThroughoutTheHour() {
        let summary = MinuteRain.summarise(minutes(Array(repeating: 9.0, count: 60)), now: start)
        XCTAssertEqual(summary?.change, .throughout)
        XCTAssertEqual(summary?.headline, "Rain for the next hour")
        XCTAssertEqual(summary?.band, "Heavy")
    }

    /// Apple types a minute *and* rates it, and the two disagree: a typed
    /// minute with no rate and a 5% chance is a possibility, not weather. Both
    /// signals have to say something before the card announces anything.
    func testTypedMinuteWithNoRateAndLowChanceIsDry() {
        let quiet = (0..<60).map { index in
            MinuteRain.Minute(at: start.addingTimeInterval(Double(index) * 60),
                              chance: 0.05, intensityMmH: 0, kind: .rain, isRadar: true)
        }
        XCTAssertEqual(MinuteRain.summarise(quiet, now: start)?.change, .dry)

        // The same minutes at a real probability are wet, rate or no rate —
        // some regions carry the odds without the millimetres.
        let likely = (0..<60).map { index in
            MinuteRain.Minute(at: start.addingTimeInterval(Double(index) * 60),
                              chance: 0.8, intensityMmH: 0, kind: .rain, isRadar: true)
        }
        XCTAssertEqual(MinuteRain.summarise(likely, now: start)?.change, .throughout)
    }

    /// A model minute clears a higher bar than a radar one. Radar has seen the
    /// thing; the hourly model is guessing at an hour that has not started, and
    /// a card that shouts about a coin flip ninety minutes out teaches a rider
    /// to ignore it — which costs them the one that is real.
    func testModelMinutesNeedBetterOddsThanRadarMinutes() {
        // Typed, but with no rate published — so the odds are all there is.
        let rates = [Double?](repeating: 0, count: 60)

        // Radar at 40% is wet; the same 40% from the model is not.
        XCTAssertEqual(MinuteRain.summarise(minutes(rates, chance: 0.4, isRadar: true),
                                            now: start)?.change, .throughout)
        XCTAssertEqual(MinuteRain.summarise(minutes(rates, chance: 0.4, isRadar: false),
                                            now: start)?.change, .dry)
        // Past the bar the model minute counts like any other.
        XCTAssertEqual(MinuteRain.summarise(minutes(rates, chance: 0.6, isRadar: false),
                                            now: start)?.change, .throughout)
    }

    /// Past the hour, "80 min" is arithmetic the reader has to do standing on
    /// a beach — which is the whole reason the window was widened.
    func testHeadlineSpellsHoursPastSixtyMinutes() {
        var rates = [Double?](repeating: nil, count: 120)
        for index in 80..<120 { rates[index] = 1.5 }
        let summary = MinuteRain.summarise(minutes(rates), now: start)
        XCTAssertEqual(summary?.change, .starting(minutesAway: 80))
        XCTAssertEqual(summary?.headline, "Rain starting in 1 hr 20 min")
        XCTAssertEqual(summary?.totalMinutes, 120)

        let dry = MinuteRain.summarise(minutes(Array(repeating: nil, count: 120)), now: start)
        XCTAssertEqual(dry?.headline, "No rain in the next two hours")
    }

    /// Minutes already behind the clock are not part of "the next hour".
    /// Apple opens the run at the current minute, but a sheet left open for a
    /// while asks again with an older array in hand.
    func testMinutesAlreadyPastAreDropped() {
        var rates = [Double?](repeating: nil, count: 60)
        for index in 30..<60 { rates[index] = 2.0 }
        // Twenty minutes later: the rain is now ten minutes out, not thirty.
        let summary = MinuteRain.summarise(minutes(rates),
                                           now: start.addingTimeInterval(20 * 60))
        XCTAssertEqual(summary?.change, .starting(minutesAway: 10))
        XCTAssertEqual(summary?.totalMinutes, 40)
    }

    /// Whatever falls for most of the hour names the hour. A changeover that
    /// starts as sleet and settles into rain is a rain shower.
    func testDominantKindNamesTheHeadline() {
        let mixed = (0..<60).map { index in
            MinuteRain.Minute(at: start.addingTimeInterval(Double(index) * 60),
                              chance: 0.9, intensityMmH: 1.0,
                              kind: index < 10 ? .sleet : .snow, isRadar: true)
        }
        XCTAssertEqual(MinuteRain.summarise(mixed, now: start)?.kind, .snow)
        XCTAssertEqual(MinuteRain.summarise(mixed, now: start)?.headline,
                       "Snow for the next hour")
    }

    // MARK: - Historical normals

    private func day(_ offset: Int, high: Double, low: Double, rain: Double) -> TypicalWeek.Day {
        TypicalWeek.Day(date: start.addingTimeInterval(Double(offset) * 86_400),
                        normalHighC: high, normalLowC: low, rainChance: rain)
    }

    private func forecast(_ offset: Int, high: Double, chancePercent: Double) -> WeatherDetail.Day {
        WeatherDetail.Day(date: start.addingTimeInterval(Double(offset) * 86_400),
                          code: 0, highC: high, lowC: nil, sunrise: nil, sunset: nil,
                          uvMax: nil, precipitationChance: chancePercent,
                          windMaxKn: nil, gustMaxKn: nil, directionDeg: nil)
    }

    func testNoNormalsMeansNoComparison() {
        XCTAssertNil(TypicalWeek().comparison(to: [forecast(0, high: 20, chancePercent: 10)]))
    }

    /// The forecast four degrees over the average, every day.
    func testWarmerThanNormalWeek() {
        let typical = TypicalWeek(days: (0..<5).map { day($0, high: 20, low: 12, rain: 0.2) })
        let ahead = (0..<5).map { forecast($0, high: 24, chancePercent: 20) }
        let comparison = typical.comparison(to: ahead)
        XCTAssertEqual(comparison?.temperatureDeltaC ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(comparison?.days, 5)
        XCTAssertTrue(comparison?.isNotable == true)
        XCTAssertFalse(comparison?.isWetter == true)
    }

    /// A degree either way is the gap between a five-day model and a
    /// thirty-year mean, not a warm spell — and the card must not claim one.
    func testSmallDifferenceIsNotNotable() {
        let typical = TypicalWeek(days: (0..<5).map { day($0, high: 20, low: 12, rain: 0.2) })
        let ahead = (0..<5).map { forecast($0, high: 21, chancePercent: 20) }
        XCTAssertEqual(typical.comparison(to: ahead)?.isNotable, false)
    }

    /// Open-Meteo answers in percent and Apple in fractions. Compared raw, a
    /// normal 20% chance against a forecast 20 would read as +19.8 — a card
    /// announcing a monsoon every single week.
    func testRainChanceUnitsAreReconciled() {
        let typical = TypicalWeek(days: (0..<5).map { day($0, high: 20, low: 12, rain: 0.2) })
        let same = (0..<5).map { forecast($0, high: 20, chancePercent: 20) }
        XCTAssertEqual(typical.comparison(to: same)?.rainDelta ?? 1, 0, accuracy: 0.001)

        let soaked = (0..<5).map { forecast($0, high: 20, chancePercent: 70) }
        let wetter = typical.comparison(to: soaked)
        XCTAssertEqual(wetter?.rainDelta ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(wetter?.isWetter == true)
    }

    /// The two sources start their weeks from their own idea of today, and
    /// pairing them by position would measure Thursday against Wednesday.
    /// Here the forecast is missing its first two days entirely.
    func testDaysAreMatchedByCalendarDayNotPosition() {
        let typical = TypicalWeek(days: (0..<5).map { day($0, high: 20, low: 12, rain: 0.2) })
        let ahead = (2..<5).map { forecast($0, high: 26, chancePercent: 20) }
        let comparison = typical.comparison(to: ahead)
        // Three days shared, each six degrees over — not five days averaged
        // against whatever happened to line up.
        XCTAssertEqual(comparison?.days, 3)
        XCTAssertEqual(comparison?.temperatureDeltaC ?? 0, 6, accuracy: 0.001)
    }

    // MARK: - Stitching radar to the hourly model

    private func samples(_ count: Int, everySeconds: TimeInterval, from: Date,
                         mmH: Double) -> [MinuteRain.Sample] {
        (0..<count).map { index in
            MinuteRain.Sample(at: from.addingTimeInterval(Double(index) * everySeconds),
                              chance: 0.9, intensityMmH: mmH, kind: .rain)
        }
    }

    /// Radar leads for as long as it runs, the model fills the rest, and the
    /// two together are exactly the window that was asked for.
    func testStitchFillsPastRadarWithTheHourlyModel() {
        let radar = samples(60, everySeconds: 60, from: start, mmH: 4)
        // Hourly entries open on the hour already under way.
        let hourly = samples(4, everySeconds: 3600, from: start.addingTimeInterval(-1800), mmH: 2)

        let minutes = MinuteRain.stitch(radar: radar, hourly: hourly, hours: 2, from: start)
        XCTAssertEqual(minutes.count, 120)
        XCTAssertEqual(minutes.filter(\.isRadar).count, 60)
        XCTAssertEqual(minutes.filter { !$0.isRadar }.count, 60)
        // Strictly increasing, one a minute, with no gap or repeat at the seam.
        for index in 1..<minutes.count {
            XCTAssertEqual(minutes[index].at.timeIntervalSince(minutes[index - 1].at), 60,
                           accuracy: 0.001, "gap at \(index)")
        }
        // The model half carries the model's rate, not the radar's.
        XCTAssertEqual(minutes[59].intensityMmH, 4)
        XCTAssertEqual(minutes[60].intensityMmH, 2)
    }

    /// No radar here — most of the world. The model carries the whole window
    /// rather than the card vanishing, which is the point of stitching at all.
    func testStitchWithoutRadarFallsBackToTheModelThroughout() {
        let hourly = samples(4, everySeconds: 3600, from: start.addingTimeInterval(-1800), mmH: 3)
        let minutes = MinuteRain.stitch(radar: [], hourly: hourly, hours: 2, from: start)

        XCTAssertEqual(minutes.count, 120)
        XCTAssertTrue(minutes.allSatisfy { !$0.isRadar })
        XCTAssertEqual(MinuteRain.summarise(minutes, now: start)?.change, .throughout)
    }

    /// A radar run that opens before now keeps only the minute in progress —
    /// and the model still picks up exactly where it stops, not where it began.
    func testStitchDropsRadarMinutesAlreadyGone() {
        let radar = samples(60, everySeconds: 60, from: start.addingTimeInterval(-20 * 60), mmH: 4)
        let hourly = samples(4, everySeconds: 3600, from: start.addingTimeInterval(-1800), mmH: 2)
        let minutes = MinuteRain.stitch(radar: radar, hourly: hourly, hours: 2, from: start)

        // Forty radar minutes survive, the model supplies the other eighty.
        XCTAssertEqual(minutes.filter(\.isRadar).count, 40)
        XCTAssertEqual(minutes.count, 120)
        XCTAssertEqual(minutes.first?.at, start)
    }

    /// An hourly run that stops short leaves the window short rather than
    /// inventing minutes to fill it.
    func testStitchStopsWhenTheModelRunsOut() {
        let hourly = samples(1, everySeconds: 3600, from: start, mmH: 3)
        let minutes = MinuteRain.stitch(radar: [], hourly: hourly, hours: 2, from: start)
        XCTAssertEqual(minutes.count, 60)
    }

    /// Six hours is three hundred and sixty minutes, which is more columns
    /// than a phone has points — so the strip pools them. The pooling is what
    /// decides whether a short squall survives being drawn.
    func testPoolingKeepsTheWorstMinuteOfEachGroup() {
        var rates = [Double?](repeating: nil, count: 12)
        // One wet minute inside the third group of four.
        rates[9] = 6.0

        let pooled = MinuteRain.pool(minutes(rates), stride: 4)
        XCTAssertEqual(pooled.count, 3)
        XCTAssertEqual(pooled.map(\.intensityMmH), [0, 0, 6])
        XCTAssertTrue(pooled[2].isWet, "the squall inside the group has to survive the pooling")
        // Columns keep their group's own place on the axis, not the worst
        // minute's — a column that jumped forward would draw the shower late.
        XCTAssertEqual(pooled[2].at, start.addingTimeInterval(8 * 60))
    }

    /// A window short enough to draw a column a minute is left exactly alone.
    func testPoolingAtStrideOneChangesNothing() {
        let run = minutes([1.0, nil, 2.0])
        XCTAssertEqual(MinuteRain.pool(run, stride: 1), run)
    }

    /// The six-hour window says its own length in every sentence it writes.
    func testSixHourWindowSpellsItsLength() {
        let dry = MinuteRain.summarise(minutes(Array(repeating: nil, count: 360)), now: start)
        XCTAssertEqual(dry?.headline, "No rain in the next 6 hours")

        var rates = [Double?](repeating: nil, count: 360)
        for index in 200..<260 { rates[index] = 3.0 }
        let wet = MinuteRain.summarise(minutes(rates), now: start)
        XCTAssertEqual(wet?.change, .starting(minutesAway: 200))
        XCTAssertEqual(wet?.headline, "Rain starting in 3 hr 20 min")
        // Spelled as a duration rather than counted out in minutes.
        XCTAssertEqual(wet?.detail?.contains("Wet for 1 hr of the next 6 hours"), true)
    }

    // MARK: - Wind normals, from the reanalysis archive

    /// Ten Augusts of daily peak wind at one point, trimmed from a real
    /// archive-api reply. Every August 18th–20th across three years, so a
    /// ±3-day window around the 19th collects all of them.
    ///
    /// The stamps carry Open-Meteo's own trap: with `timeformat=unixtime` a
    /// *daily* stamp is local midnight written as though it were GMT, so
    /// 1471590000 is 2016-08-19T07:00Z and means August 19th at GMT-7. Read in
    /// the phone's zone it can be the 18th, which would file every row under
    /// the wrong day.
    private func archiveFixture() -> Data {
        var times: [Int] = []
        var speeds: [Double] = []
        var directions: [Double] = []
        // 2016-08-18, -19, -20 then the same three days in 2017 and 2018.
        let augusts = [1_471_503_600, 1_503_039_600, 1_534_575_600]
        for (year, base) in augusts.enumerated() {
            for day in 0..<3 {
                times.append(base + day * 86_400)
                // 10, 12, 14 / 16, 18, 20 / 22, 24, 26 — nine samples whose
                // quartiles are known by hand.
                speeds.append(Double(10 + year * 6 + day * 2))
                directions.append(280)
            }
        }
        let json = """
        {"utc_offset_seconds":-25200,"timezone":"America/Los_Angeles","daily":{
            "time":\(times),
            "wind_speed_10m_max":\(speeds),
            "wind_direction_10m_dominant":\(directions)}}
        """
        return Data(json.utf8)
    }

    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// The window pools every year's nearby days into one distribution, and
    /// the middle half of it is what the card draws.
    func testWindNormalsPoolTheWindowAcrossYears() {
        // 2026-08-19, local midnight in the Pacific zone.
        let target = Date(timeIntervalSince1970: 1_787_122_800)
        let wind = OpenMeteo.parseTypicalWind(archiveFixture(), for: [target], calendar: pacific)

        XCTAssertEqual(wind.days.count, 1)
        let day = wind.days.first
        // All nine samples: 10,12,14,16,18,20,22,24,26.
        XCTAssertEqual(day?.samples, 9)
        XCTAssertEqual(day?.medianKn, 18)
        XCTAssertEqual(day?.lowKn, 14)
        XCTAssertEqual(day?.highKn, 22)
        XCTAssertEqual(day?.directionDeg ?? 0, 280, accuracy: 0.001)
    }

    /// A date with almost nothing behind it gets no row at all. Five samples
    /// is not a normal, and a band drawn from two would be a confident lie.
    func testSparseWindowIsDropped() {
        // Mid-January, nowhere near the August rows in the fixture.
        let january = Date(timeIntervalSince1970: 1_768_464_000)
        let wind = OpenMeteo.parseTypicalWind(archiveFixture(), for: [january], calendar: pacific)
        XCTAssertTrue(wind.isEmpty)
    }

    /// February 29th folds onto the 28th, and the window wraps the new year
    /// rather than running off the end of the array.
    func testDaySlotsFoldLeapDayAndCoverTheWholeYear() {
        XCTAssertEqual(OpenMeteo.daySlot(month: 1, day: 1), 0)
        XCTAssertEqual(OpenMeteo.daySlot(month: 12, day: 31), 364)
        XCTAssertEqual(OpenMeteo.daySlot(month: 2, day: 29), OpenMeteo.daySlot(month: 2, day: 28))
        XCTAssertNil(OpenMeteo.daySlot(month: 13, day: 1))

        // A window three days either side of New Year's Eve has to reach into
        // January, or the card goes quiet for a week every winter.
        let eve = OpenMeteo.daySlot(month: 12, day: 31) ?? 0
        let wrapped = ((eve + 2) % 365 + 365) % 365
        XCTAssertEqual(wrapped, OpenMeteo.daySlot(month: 1, day: 2))
    }

    /// Bearings average the short way round. 350° and 10° are 20° apart and
    /// average to 0°; the arithmetic mean says 180°, the exact opposite, and a
    /// card claiming an offshore wind was onshore is worse than no card.
    func testPrevailingDirectionAveragesAsVectors() {
        // Compared the short way round, because these are bearings. Due north
        // falls out of the vector sum as 359.999… about as often as 0.000…,
        // and asserting numeric equality on that tests floating point rather
        // than the maths.
        let north = TypicalWind.circularMean(of: [350, 10])
        XCTAssertEqual(Geo.angleSeparation(north ?? 180, 0), 0, accuracy: 0.001)
        // And emphatically not the arithmetic mean's answer, which is 180° —
        // the exact opposite, an offshore wind reported as onshore.
        XCTAssertEqual(Geo.angleSeparation(north ?? 0, 180), 180, accuracy: 0.001)

        XCTAssertEqual(TypicalWind.circularMean(of: [90, 110]) ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(TypicalWind.circularMean(of: []))
    }

    /// The wind verdict is the forecast's peaks against the normal middles,
    /// paired by calendar day like the temperature half.
    func testWindComparisonMeasuresForecastPeaksAgainstNormals() {
        let days = (0..<4).map { offset in
            TypicalWind.Day(date: start.addingTimeInterval(Double(offset) * 86_400),
                            lowKn: 12, highKn: 22, medianKn: 17,
                            directionDeg: 280, samples: 70)
        }
        let ahead = (0..<4).map { offset in
            WeatherDetail.Day(date: start.addingTimeInterval(Double(offset) * 86_400),
                              code: 0, highC: 20, lowC: nil, sunrise: nil, sunset: nil,
                              uvMax: nil, precipitationChance: 10, windMaxKn: 11,
                              gustMaxKn: nil, directionDeg: nil)
        }
        let delta = TypicalWind(days: days).comparison(to: ahead)
        XCTAssertEqual(delta ?? 0, -6, accuracy: 0.001)
        XCTAssertNil(TypicalWind().comparison(to: ahead))
    }

    /// A day the forecast has no high for contributes nothing rather than a
    /// zero, which would drag the average toward "twenty degrees below normal".
    func testMissingForecastHighIsSkippedNotCountedAsZero() {
        let typical = TypicalWeek(days: (0..<3).map { day($0, high: 20, low: 12, rain: 0.2) })
        var ahead = (0..<3).map { forecast($0, high: 25, chancePercent: 20) }
        ahead[1] = WeatherDetail.Day(date: ahead[1].date, code: 0, highC: nil, lowC: nil,
                                     sunrise: nil, sunset: nil, uvMax: nil,
                                     precipitationChance: 20, windMaxKn: nil,
                                     gustMaxKn: nil, directionDeg: nil)
        let comparison = typical.comparison(to: ahead)
        XCTAssertEqual(comparison?.days, 2)
        XCTAssertEqual(comparison?.temperatureDeltaC ?? 0, 5, accuracy: 0.001)
    }
}
