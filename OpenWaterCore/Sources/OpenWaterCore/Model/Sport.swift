import Foundation

/// The discipline a session was ridden in.
///
/// Sport selection drives detection thresholds (takeoff speed, turn sharpness,
/// pump band) rather than just being a label.
public enum Sport: String, CaseIterable, Sendable, Codable, Identifiable {
    case wingfoil
    case parawing
    case windsurf
    case windfoil
    case kitesurf
    case kitefoil
    case downwindSUP
    case sup
    case prone
    case sail
    case kayak
    case efoil
    case tow
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wingfoil: "Wingfoil"
        case .parawing: "Parawing"
        case .windsurf: "Windsurf"
        case .windfoil: "Windfoil"
        case .kitesurf: "Kitesurf"
        case .kitefoil: "Kitefoil"
        case .downwindSUP: "Downwind SUP"
        case .sup: "SUP"
        case .prone: "Prone Foil"
        case .sail: "Sailing"
        case .kayak: "Kayak"
        case .efoil: "eFoil"
        case .tow: "Tow / Dock Start"
        case .other: "Other"
        }
    }

    /// SF Symbols name.
    ///
    /// Every name here is verified to exist — `kite` was not a real symbol and
    /// rendered as blank space in the picker, which is a silent failure: the row
    /// still tapped, it just looked broken. `SportIconTests` asserts the whole
    /// set resolves so that cannot happen again.
    ///
    /// Sports are also given distinct icons rather than one `wind` for all five
    /// wind disciplines, so the picker can be scanned rather than read.
    public var symbolName: String {
        switch self {
        // Wind held in the hands.
        case .wingfoil: "wind"
        case .parawing: "paperplane"
        // Rig on the board.
        case .windsurf: "sailboat"
        case .windfoil: "sailboat.fill"
        // Kite overhead.
        case .kitesurf: "figure.wave"
        case .kitefoil: "figure.wave.circle"
        // Boat.
        case .sail: "figure.sailing"
        // Paddle and prone.
        case .downwindSUP: "water.waves"
        case .sup: "figure.surfing"
        case .prone: "surfboard"
        case .kayak: "figure.outdoor.rowing"
        // Powered.
        case .efoil: "bolt.horizontal"
        case .tow: "arrow.up.forward"
        case .other: "figure.open.water.swim"
        }
    }

    /// Sports where the rider is powered by the wind and therefore has a
    /// meaningful wind angle, polar and tack/gybe structure.
    public var isWindPowered: Bool {
        switch self {
        case .wingfoil, .parawing, .windsurf, .windfoil, .kitesurf, .kitefoil, .sail:
            true
        case .downwindSUP, .sup, .prone, .kayak, .efoil, .tow, .other:
            false
        }
    }

    /// Sports ridden on a hydrofoil, where flight detection applies.
    public var isFoiling: Bool {
        switch self {
        case .wingfoil, .parawing, .windfoil, .kitefoil, .prone, .efoil, .downwindSUP:
            true
        case .windsurf, .kitesurf, .sup, .sail, .kayak, .tow, .other:
            false
        }
    }

    /// Sports where a rhythmic pump or stroke is worth counting.
    public var hasCadence: Bool {
        switch self {
        case .wingfoil, .parawing, .downwindSUP, .sup, .prone, .kayak: true
        default: false
        }
    }

    /// Tuning constants that make detection behave sensibly per discipline.
    public var thresholds: SportThresholds { SportThresholds.forSport(self) }

    /// Every sport, ordered by how likely a rider of this app is to pick it.
    ///
    /// `allCases` is declaration order, which is not the order anyone wants to
    /// choose from. This is the list every picker uses.
    public static let recordable: [Sport] = [
        .wingfoil, .parawing, .downwindSUP, .prone,
        .windfoil, .windsurf, .kitefoil, .kitesurf,
        .sail, .sup, .kayak, .efoil, .tow, .other,
    ]
}

/// Per-sport tuning for the detectors. Every value is overridable in Settings —
/// these are the defaults that work for most riders.
public struct SportThresholds: Hashable, Sendable, Codable {

    /// Below this the rider is considered stopped (auto-pause, moving time).
    public var movingSpeed: Double            // m/s

    /// Sustained speed at which a foil is generating enough lift to fly.
    public var foilTakeoffSpeed: Double       // m/s

    /// Vertical-acceleration standard deviation below which the ride is "smooth"
    /// — the signature of being out of the water.
    public var foilSmoothnessSD: Double       // m/s²

    /// Minimum time above the takeoff conditions before it counts as a flight.
    public var minFlightDuration: TimeInterval

    /// Cumulative heading change that makes a direction change a "maneuver".
    public var maneuverHeadingChange: Double  // degrees

    /// Longest a maneuver may take before it is just sailing a curve.
    public var maneuverMaxDuration: TimeInterval

    /// Frequency band searched for pump / stroke cadence.
    public var cadenceBandHz: ClosedRange<Double>

    /// Fixes worse than this are dropped outright.
    public var maxHorizontalAccuracy: Double  // metres

    /// Physically impossible for the sport — used to reject GPS spikes.
    public var maxPlausibleSpeed: Double      // m/s

    public static func forSport(_ sport: Sport) -> SportThresholds {
        var t = SportThresholds(
            movingSpeed: 1.0,
            foilTakeoffSpeed: 4.5,
            foilSmoothnessSD: 1.6,
            minFlightDuration: 3.0,
            maneuverHeadingChange: 70,
            maneuverMaxDuration: 12,
            cadenceBandHz: 0.4...3.0,
            maxHorizontalAccuracy: 12,
            maxPlausibleSpeed: 30            // ~58 kn
        )
        switch sport {
        case .wingfoil, .parawing:
            t.foilTakeoffSpeed = 4.5          // ~8.7 kn
            t.maxPlausibleSpeed = 25
        case .windfoil, .kitefoil:
            t.foilTakeoffSpeed = 5.5
            t.maxPlausibleSpeed = 32
        case .windsurf:
            t.foilTakeoffSpeed = .infinity    // no flight phase
            t.movingSpeed = 1.5
            t.maxPlausibleSpeed = 35          // world record territory is ~27 m/s
        case .kitesurf:
            t.foilTakeoffSpeed = .infinity
            t.movingSpeed = 1.5
            t.maxPlausibleSpeed = 35
        case .downwindSUP, .prone:
            t.foilTakeoffSpeed = 3.5
            t.movingSpeed = 0.8
            t.maxPlausibleSpeed = 15
        case .sup, .kayak:
            t.foilTakeoffSpeed = .infinity
            t.movingSpeed = 0.5
            t.maneuverHeadingChange = 90
            t.maxPlausibleSpeed = 8
        case .sail:
            t.foilTakeoffSpeed = .infinity
            t.movingSpeed = 0.5
            t.maneuverMaxDuration = 25        // keelboats turn slowly
            t.maxPlausibleSpeed = 20
        case .efoil, .tow:
            t.foilTakeoffSpeed = 4.0
            t.maxPlausibleSpeed = 20
        case .other:
            break
        }
        return t
    }
}
