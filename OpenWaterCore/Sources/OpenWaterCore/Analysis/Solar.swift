import Foundation

/// Sunrise, sunset and the light that matters to a rider, from the NOAA
/// solar-position equations. Pure arithmetic — no network, no location
/// services of its own — so the after-work question ("do I have time?") gets
/// answered on a beach with no signal.
public enum Solar {

    public struct Day: Sendable, Equatable {
        public let sunrise: Date?
        public let sunset: Date?
        /// Sun 6° below the horizon — the end of civil twilight, and the
        /// honest definition of "last usable light" on the water.
        public let civilDusk: Date?
        /// Sun at 6° *above* the horizon on the way down — the start of the
        /// hour photographers fight over and riders get for free.
        public let goldenHourStart: Date?
    }

    /// The sun's day at a place, for the calendar date containing `date`.
    public static func day(
        latitude: Double,
        longitude: Double,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> Day {
        Day(
            sunrise: crossing(latitude: latitude, longitude: longitude, on: date,
                              calendar: calendar, altitude: -0.833, rising: true),
            sunset: crossing(latitude: latitude, longitude: longitude, on: date,
                             calendar: calendar, altitude: -0.833, rising: false),
            civilDusk: crossing(latitude: latitude, longitude: longitude, on: date,
                                calendar: calendar, altitude: -6, rising: false),
            goldenHourStart: crossing(latitude: latitude, longitude: longitude, on: date,
                                      calendar: calendar, altitude: 6, rising: false)
        )
    }

    /// When the sun's centre crosses `altitude` degrees, rising or setting,
    /// on the given calendar day. Nil in polar conditions where it never does.
    static func crossing(
        latitude: Double,
        longitude: Double,
        on date: Date,
        calendar: Calendar,
        altitude: Double,
        rising: Bool
    ) -> Date? {
        // Anchor everything to 00:00 UTC of the rider's *calendar date* —
        // not the UTC day containing local solar noon, which for any place
        // west of about 60°W is the following UTC day and pushed every
        // answer 24 hours into the future. The tests originally compared
        // only clock hours, so a whole-day error passed them; the countdown
        // on the Daylight screen is what caught it, reading "36 hours of
        // light left".
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let utcDayStart = utcCalendar.date(from: components) else { return nil }
        // Solar parameters evaluated at this place's solar noon on that day.
        let noon = utcDayStart.addingTimeInterval((12 - longitude / 15) * 3600)
        let julian = noon.timeIntervalSince1970 / 86400 + 2440587.5
        let century = (julian - 2451545) / 36525

        // Solar coordinates (degrees), NOAA's low-precision series — good to
        // well under a minute of clock time, which is all daylight needs.
        let meanLongitude = Geo.normalizeDegrees(280.46646 + century * (36000.76983 + century * 0.0003032))
        let meanAnomaly = 357.52911 + century * (35999.05029 - 0.0001537 * century)
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century)
        let anomalyRad = meanAnomaly * .pi / 180
        let centre = sin(anomalyRad) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sin(2 * anomalyRad) * (0.019993 - 0.000101 * century)
            + sin(3 * anomalyRad) * 0.000289
        let trueLongitude = meanLongitude + centre
        let apparentLongitude = trueLongitude - 0.00569
            - 0.00478 * sin((125.04 - 1934.136 * century) * .pi / 180)
        let obliquity = 23.439291 - century * 0.0130042
            + 0.00256 * cos((125.04 - 1934.136 * century) * .pi / 180)
        let declination = asin(sin(obliquity * .pi / 180) * sin(apparentLongitude * .pi / 180)) * 180 / .pi

        // Equation of time, minutes.
        let y = pow(tan(obliquity / 2 * .pi / 180), 2)
        let meanLongRad = meanLongitude * .pi / 180
        let equationOfTime = 4 * (180 / .pi) * (
            y * sin(2 * meanLongRad)
            - 2 * eccentricity * sin(anomalyRad)
            + 4 * eccentricity * y * sin(anomalyRad) * cos(2 * meanLongRad)
            - 0.5 * y * y * sin(4 * meanLongRad)
            - 1.25 * eccentricity * eccentricity * sin(2 * anomalyRad)
        )

        // Hour angle at which the sun sits at the target altitude.
        let latRad = latitude * .pi / 180
        let decRad = declination * .pi / 180
        let altRad = altitude * .pi / 180
        let cosHourAngle = (sin(altRad) - sin(latRad) * sin(decRad)) / (cos(latRad) * cos(decRad))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi

        // Minutes past the anchor's midnight UTC. West of Greenwich these
        // exceed 1440 and land on the next UTC day — which is exactly the
        // rider's same local evening.
        let solarNoonMinutes = 720 - 4 * longitude - equationOfTime
        let minutes = rising
            ? solarNoonMinutes - 4 * hourAngle
            : solarNoonMinutes + 4 * hourAngle
        return utcDayStart.addingTimeInterval(minutes * 60)
    }
}

extension Solar {
    /// How a run lines up with the wind.
    ///
    /// `bearing` is the direction of travel launch → takeout; dead downwind
    /// means travelling the way the wind blows, which is `directionFrom +
    /// 180`. Returns degrees off that ideal, `0...180`.
    public static func runAlignment(bearing: Double, windFrom: Double) -> Double {
        Geo.angleSeparation(bearing, Geo.normalizeDegrees(windFrom + 180))
    }
}
