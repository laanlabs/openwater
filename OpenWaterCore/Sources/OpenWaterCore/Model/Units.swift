import Foundation

/// Speed unit for display. Internally everything is metres per second.
public enum SpeedUnit: String, CaseIterable, Sendable, Codable {
    case knots
    case kmh
    case mph
    case ms

    /// Multiply a m/s value by this to get the display value.
    public var perMetrePerSecond: Double {
        switch self {
        case .knots: 1.943_844_492_440_605
        case .kmh: 3.6
        case .mph: 2.236_936_292_054_402
        case .ms: 1
        }
    }

    public var symbol: String {
        switch self {
        case .knots: "kn"
        case .kmh: "km/h"
        case .mph: "mph"
        case .ms: "m/s"
        }
    }

    public func convert(fromMetresPerSecond value: Double) -> Double {
        value * perMetrePerSecond
    }

    public func toMetresPerSecond(_ value: Double) -> Double {
        value / perMetrePerSecond
    }
}

/// Distance unit for display.
public enum DistanceUnit: String, CaseIterable, Sendable, Codable {
    case metric        // m / km
    case nautical      // m / NM
    case imperial      // ft / mi

    public static let metresPerNauticalMile: Double = 1852
    public static let metresPerStatuteMile: Double = 1609.344
    public static let metresPerFoot: Double = 0.3048

    /// The unit a session-length distance is shown in. Deliberately the *large*
    /// unit even when a short session would be formatted in metres — it labels
    /// a column, and a column heading that changes per row is worse than one
    /// that is occasionally approximate.
    public var symbol: String {
        switch self {
        case .metric: "km"
        case .nautical: "NM"
        case .imperial: "mi"
        }
    }

    /// A height in this unit's own numbers, with nothing printed.
    ///
    /// `Format.height` renders the string; a chart axis needs the bare value
    /// and labels itself. They share this so an axis and the caption under it
    /// can never end up in different units — which is the specific way a wave
    /// chart lies: "1.2" against a legend reading feet, drawn from metres.
    public func heightValue(fromMetres metres: Double) -> Double {
        switch self {
        case .metric, .nautical: metres
        case .imperial: metres / Self.metresPerFoot
        }
    }

    /// Metres per display unit.
    public var metresPerUnit: Double {
        switch self {
        case .metric: 1000
        case .nautical: Self.metresPerNauticalMile
        case .imperial: Self.metresPerStatuteMile
        }
    }
}

/// The user's display preferences. Purely presentational — never affects analysis.
public struct UnitPreferences: Hashable, Sendable, Codable {
    public var speed: SpeedUnit
    public var distance: DistanceUnit

    /// Optional in storage so preferences saved before it existed still
    /// decode; read it through `temperatureUnit`.
    public var temperature: TemperatureUnit?

    /// What the weather is shown in. Celsius unless the rider says otherwise.
    public var temperatureUnit: TemperatureUnit { temperature ?? .celsius }

    /// Knots and nautical miles are what the water speaks.
    public static let `default` = UnitPreferences(speed: .knots, distance: .metric)

    public init(speed: SpeedUnit = .knots, distance: DistanceUnit = .metric,
                temperature: TemperatureUnit? = nil) {
        self.speed = speed
        self.distance = distance
        self.temperature = temperature
    }

    /// What this phone is already set up for.
    ///
    /// A first launch should agree with the rest of the device rather than
    /// making somebody in Texas convert every reading in their head. Speed
    /// stays in knots regardless — it is the unit the sport is measured in
    /// everywhere, and a speed-sailing figure in mph is not comparable with
    /// anybody else's.
    public static var forThisDevice: UnitPreferences {
        let metric = Locale.current.measurementSystem != .us
        return UnitPreferences(
            speed: .knots,
            distance: metric ? .metric : .imperial,
            temperature: metric ? .celsius : .fahrenheit
        )
    }
}

/// How the weather is shown.
public enum TemperatureUnit: String, Sendable, Codable, CaseIterable, Identifiable {
    case celsius, fahrenheit

    public var id: String { rawValue }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public var shortSymbol: String { "°" }
    public var title: String { self == .celsius ? "Celsius" : "Fahrenheit" }

    public func convert(fromCelsius value: Double) -> Double {
        self == .celsius ? value : value * 9 / 5 + 32
    }
}

// MARK: - Formatting

public enum Format {

    /// A temperature from Celsius, which is what every source here speaks.
    public static func temperature(
        _ celsius: Double, unit: TemperatureUnit, includeSymbol: Bool = true
    ) -> String {
        let value = Int(unit.convert(fromCelsius: celsius).rounded())
        return includeSymbol ? "\(value)\(unit.symbol)" : "\(value)°"
    }

    public static func speed(
        _ metresPerSecond: Double,
        unit: SpeedUnit,
        decimals: Int = 2,
        includeSymbol: Bool = true
    ) -> String {
        let v = unit.convert(fromMetresPerSecond: metresPerSecond)
        let n = String(format: "%.\(decimals)f", v)
        return includeSymbol ? "\(n) \(unit.symbol)" : n
    }

    /// The distance in the unit's large denomination, unlabelled — for a column
    /// that carries its own heading.
    public static func distance(
        _ metres: Double,
        unit: DistanceUnit,
        includeSymbol: Bool,
        decimals: Int = 2
    ) -> String {
        guard !includeSymbol else { return distance(metres, unit: unit) }
        return String(format: "%.\(decimals)f", metres / unit.metresPerUnit)
    }

    public static func distance(_ metres: Double, unit: DistanceUnit) -> String {
        switch unit {
        case .metric:
            metres < 1000
                ? String(format: "%.0f m", metres)
                : String(format: "%.2f km", metres / 1000)
        case .nautical:
            metres < DistanceUnit.metresPerNauticalMile
                ? String(format: "%.0f m", metres)
                : String(format: "%.2f NM", metres / DistanceUnit.metresPerNauticalMile)
        case .imperial:
            metres < DistanceUnit.metresPerStatuteMile
                ? String(format: "%.0f ft", metres / DistanceUnit.metresPerFoot)
                : String(format: "%.2f mi", metres / DistanceUnit.metresPerStatuteMile)
        }
    }

    /// A small vertical distance — swell, or how high a jump went.
    ///
    /// Separate from `distance` because that one switches denomination on
    /// magnitude: a 1.8 m jump would come out as "1.8 m" under metric and
    /// "6 ft" under imperial, which is right, but a 2 km run and a 2 m jump
    /// have no business sharing a formatter. Heights stay in metres or feet
    /// whatever the number, and keep a decimal — riders quote 1.8 m, not 2 m.
    public static func height(_ metres: Double, unit: DistanceUnit) -> String {
        // Negative zero is a real number and a silly reading. A tide table
        // running a hair under the datum prints "-0.0 ft", which looks like
        // a bug in a column of otherwise sober numbers; the sign only earns
        // its place once it changes a digit.
        func shown(_ value: Double) -> Double { abs(value) < 0.05 ? 0 : value }
        let value = shown(unit.heightValue(fromMetres: metres))
        switch unit {
        case .metric, .nautical: return String(format: "%.1f m", value)
        case .imperial: return String(format: "%.1f ft", value)
        }
    }

    /// `1:23:45` or `23:45` — compact enough for a watch face.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// `12.3 s` for short intervals like a flight or a gybe.
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1f s", seconds)
            : duration(seconds)
    }

    /// Compass bearing as `045°` plus the cardinal name.
    public static func bearing(_ degrees: Double, includeCardinal: Bool = true) -> String {
        let d = Geo.normalizeDegrees(degrees)
        let n = String(format: "%03.0f°", d)
        return includeCardinal ? "\(n) \(cardinal(d))" : n
    }

    public static func cardinal(_ degrees: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let i = Int((Geo.normalizeDegrees(degrees) / 22.5).rounded()) % 16
        return names[i]
    }
}
