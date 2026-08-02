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

    /// The accuracy the post-session build would *like* every fix to meet.
    ///
    /// Strict on purpose — a saved session's numbers are claims — but it is a
    /// preference, not a guillotine. `TrackBuilder` raises it when a recording's
    /// own spread says these fixes are simply what this receiver managed today,
    /// because a flat limit applied to a real session deleted nine tenths of
    /// it. See `TrackBuilder.Options.accuracyOutlierSigmas`.
    public var maxHorizontalAccuracy: Double  // metres

    /// Fixes worse than this are ignored by the *live* screens.
    ///
    /// Deliberately far looser than the one above, because the two are
    /// answering different questions. The recorded analysis is a claim about
    /// how fast somebody went; the live screen is a rider glancing at their
    /// wrist. Holding the live display to record-grade accuracy meant that a
    /// cold receiver, a car park, or a hand over the watch froze the numbers
    /// completely — every fix silently discarded, the speed stuck on its last
    /// value, and nothing on screen to say why. A slightly noisy number now
    /// beats a frozen one; the session is still built strictly afterwards.
    public var liveAccuracyLimit: Double      // metres

    /// Physically impossible for the sport — used to reject GPS spikes.
    public var maxPlausibleSpeed: Double      // m/s

    /// How the receiver should be driven for a sport.
    ///
    /// Kept in plain values rather than `CLLocationAccuracy` and friends so the
    /// model layer stays platform-free — `LocationProvider` translates it. The
    /// distinction that matters is battery against resolution: three hours of
    /// navigation-grade fixes is a real cost, and a kayak tour does not need
    /// what a speed run does.
    public struct LocationProfile: Sendable, Hashable {

        public enum Accuracy: Sendable, Hashable {
            /// The most the receiver can give, and the mode that keeps Doppler
            /// speed flowing. Everything on foil uses this.
            case navigation
            /// Best available without the navigation-grade power draw.
            case best
        }

        public enum Activity: Sendable, Hashable {
            case otherNavigation, fitness
        }

        public var accuracy: Accuracy
        public var activity: Activity
        /// Metres a rider must move before a new fix is delivered. Always nil
        /// for recording — a distance filter destroys the even sampling every
        /// windowed metric assumes — but named here so it cannot be set by
        /// accident somewhere else.
        public var distanceFilter: Double?

        public init(accuracy: Accuracy, activity: Activity, distanceFilter: Double? = nil) {
            self.accuracy = accuracy
            self.activity = activity
            self.distanceFilter = distanceFilter
        }
    }

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
            liveAccuracyLimit: 35,
            maxPlausibleSpeed: 30            // ~58 kn
        )
        switch sport {
        case .wingfoil, .parawing:
            t.foilTakeoffSpeed = 4.5          // ~8.7 kn
            t.maxPlausibleSpeed = 25
            // Foiling is where a lost second actually costs something: the runs
            // are short, the accelerations are sharp, and a gap in the fixes
            // lands straight in the 2-second peak. Take everything the receiver
            // offers and let the post-session build throw the rubbish away.
            t.liveAccuracyLimit = 50
        case .windfoil, .kitefoil:
            t.foilTakeoffSpeed = 5.5
            t.maxPlausibleSpeed = 32
            t.liveAccuracyLimit = 50
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
            t.liveAccuracyLimit = 50
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
            t.liveAccuracyLimit = 50
        case .other:
            break
        }
        return t
    }
}


extension Sport {

    /// How to drive the receiver for this sport.
    ///
    /// Everything that flies gets navigation-grade fixes in the foreground and
    /// the background alike, because that is the mode Doppler speed arrives in
    /// and a foiling run is over in twenty seconds. Paddling and sailing get
    /// the same delivery rate — iOS gives about one fix a second either way —
    /// at a slightly lower power draw, which matters over a four-hour crossing.
    public var locationProfile: SportThresholds.LocationProfile {
        switch self {
        case .wingfoil, .parawing, .windfoil, .kitefoil, .downwindSUP, .prone, .efoil, .tow,
             .windsurf, .kitesurf:
            SportThresholds.LocationProfile(accuracy: .navigation, activity: .otherNavigation)
        case .sup, .kayak, .sail, .other:
            SportThresholds.LocationProfile(accuracy: .best, activity: .otherNavigation)
        }
    }
}
