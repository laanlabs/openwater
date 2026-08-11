import Foundation

/// Parses NDBC's `.spec` spectral summary files — the *measured* version of
/// the swell/wind-wave split the marine model only forecasts.
///
/// Every buoy with a wave sensor publishes a realtime2 `.spec` file beside
/// its standard met file: for each reading, the significant height split
/// into a swell train and a wind-wave train, with periods, directions and a
/// steepness word. It is the one free source that can answer "did the model
/// get the split right", which is why the parser lives in core where it can
/// be tested — the fetch stays in the app with the other networking.
///
/// The format is ragged in three ways this parser must survive: any field
/// can be `MM` (sensor not reporting); the split directions come as
/// sixteen-point compass letters ("WNW") while the mean direction is
/// degrees; and some wave buoys never report the split at all, filling
/// every split column with `MM` while WVHT stays real.
public enum NDBCSpectral {

    /// One measured reading — the newest row is the current sea state.
    public struct Reading: Hashable, Sendable {
        /// When the buoy measured, UTC.
        public var at: Date
        /// Combined significant height, metres — the number that should
        /// roughly match the model's `wave_height`.
        public var waveHeightM: Double?
        /// The measured swell train, when the buoy resolved one.
        public var swell: SwellTrain?
        /// The measured wind-wave train.
        public var windWave: SwellTrain?
        /// Average period across the whole spectrum, seconds.
        public var averagePeriodS: Double?
        /// Mean wave direction, degrees true, waves coming *from*.
        public var meanDirectionDeg: Double?
        /// NDBC's one-word character call: "SWELL", "WIND SEA", "AVERAGE",
        /// "STEEP", "VERY STEEP". Kept verbatim; `nil` for "N/A".
        public var steepness: String?
    }

    /// Rows newest-first, the order the file keeps them in.
    public static func parse(_ text: String) -> [Reading] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        return text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { row -> Reading? in
                let columns = row.split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                // #YY MM DD hh mm WVHT SwH SwP WWH WWP SwD WWD STEEPNESS APD MWD
                //   0  1  2  3  4    5   6   7   8   9  10  11        12  13  14
                guard columns.count >= 15 else { return nil }

                // Indices 0–14 are safe behind the count guard above.
                func value(_ index: Int) -> Double? {
                    let raw = columns[index]
                    return raw == "MM" ? nil : Double(raw)
                }
                func direction(_ index: Int) -> Double? {
                    let raw = columns[index]
                    guard raw != "MM" else { return nil }
                    // Split directions arrive as compass letters, the mean
                    // direction as degrees — accept either, trust neither.
                    return Double(raw) ?? degrees(fromCardinal: raw)
                }
                func train(height: Int, period: Int, from: Int) -> SwellTrain? {
                    guard let h = value(height), h > 0.01 else { return nil }
                    return SwellTrain(heightM: h, periodS: value(period),
                                      directionFromDeg: direction(from))
                }

                var stamp = DateComponents()
                stamp.year = value(0).map(Int.init)
                stamp.month = value(1).map(Int.init)
                stamp.day = value(2).map(Int.init)
                stamp.hour = value(3).map(Int.init)
                stamp.minute = value(4).map(Int.init)
                guard let at = utc.date(from: stamp) else { return nil }

                let steepness = columns[12]
                return Reading(
                    at: at,
                    waveHeightM: value(5),
                    swell: train(height: 6, period: 7, from: 10),
                    windWave: train(height: 8, period: 9, from: 11),
                    averagePeriodS: value(13),
                    meanDirectionDeg: value(14),
                    steepness: steepness == "N/A" || steepness == "MM" ? nil : steepness
                )
            }
    }

    /// Sixteen-point compass name to degrees true. `nil` for anything that
    /// is not one — this is a lookup, not a guesser.
    public static func degrees(fromCardinal raw: String) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard let index = points.firstIndex(of: raw.uppercased()) else { return nil }
        return Double(index) * 22.5
    }
}
