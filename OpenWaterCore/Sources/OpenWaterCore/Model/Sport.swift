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

    // MARK: What counts as a glide

    /// Shortest stretch that can be a glide, seconds.
    public var glideMinimumDuration: TimeInterval = 5

    /// How far off the wind a glide has to be sailed, degrees. A bump can only
    /// push you the way it is going, so anything nearer the wind than this is
    /// riding across the swell rather than being carried by it.
    public var glideDownwindAngle: Double = 100

    /// A glide must reach this fraction of the rider's own median downwind
    /// speed. A fraction near one splits their riding in half by construction,
    /// so this sits well below it — the job is to exclude *not riding*, not to
    /// exclude the slower half of riding.
    public var glideSpeedFraction: Double = 0.75

    /// How much faster a glide has to get than the lull it rose out of, as a
    /// fraction. Without a rise there is nothing to say the water did the work.
    public var glideMinimumGain: Double = 0.05

    // MARK: What counts as a wave ride

    /// Every rule below is optional, and `nil` means "keep borrowing the
    /// glide detector's answer" — which is what the wave finder did before
    /// any of them existed. A rider who has never opened the wave rules sees
    /// exactly the rides they saw before, their own glide tuning included;
    /// setting one takes that rule off the glide rail for waves alone.

    /// Degrees either side of the swell's travel a ride may point. Straight
    /// down the face is 0°, down the line is 40–60°. Inherits
    /// `WaveRideFinder.halfAngle`.
    public var waveConeAngle: Double?

    /// The fraction of the rider's own median with-the-swell speed a ride has
    /// to hold. Inherits `glideSpeedFraction`.
    public var waveSpeedFraction: Double?

    /// How much the wave has to add over the lull before it, as a fraction.
    /// Inherits the firmer of `glideMinimumGain` and
    /// `WaveRideFinder.minimumGain`.
    public var waveMinimumGain: Double?

    /// Shortest stretch worth naming a ride, seconds. Inherits
    /// `glideMinimumDuration`.
    public var waveMinimumDuration: TimeInterval?

    /// How long a carve out of the cone a ride survives, seconds — a turn up
    /// the face points away for a beat and comes back. Inherits eight.
    public var waveBridgeSeconds: TimeInterval?

    /// How noisy the accelerometer may be with the rider still counted as
    /// riding, as a multiple of the session's own median. Inherits
    /// `pumpEnergyFraction`.
    ///
    /// At or above `waveChopIgnored` the reading is not consulted at all.
    /// That is a real answer and not a cop-out: on a wing in short chop the
    /// deck is never quiet, and a bar tuned on a smooth groundswell ends a
    /// ride the rider is visibly still on — eleven knots, twenty degrees off
    /// the swell, and cut because the board was rattling.
    public var waveQuietFraction: Double?

    /// The value of `waveQuietFraction` at which the accelerometer stops
    /// being consulted at all.
    public static let waveChopIgnored: Double = 5

    // MARK: What counts as an upwind leg

    /// How far off the wind you may point and still be working upwind,
    /// degrees. Ninety is a beam reach — beyond it you are no longer climbing.
    public var upwindLegAngle: Double = 90

    /// Shortest leg worth measuring, metres. Low on purpose: a real session's
    /// zig-zag is made of short tacks, and a high floor swallows half of it.
    public var upwindLegMinimumDistance: Double = 80

    /// Shortest leg worth measuring, seconds.
    public var upwindLegMinimumDuration: TimeInterval = 12

    // MARK: What counts as a jump

    /// Shortest airtime worth reporting, seconds.
    public var jumpMinimumAirtime: TimeInterval = 0.6

    /// User acceleration below which the board is in free fall, m/s². In the
    /// air the only force on it is gravity, so the acceleration the device
    /// reports — gravity already removed — collapses toward zero. Raising this
    /// finds more jumps and more things that were not jumps.
    public var jumpFreeFall: Double = 2.5

    /// How hard the landing spike has to be, m/s². A kite lands softly under
    /// canopy; a wing drops you.
    public var jumpLandingSpike: Double = 12

    /// You cannot jump from a standstill, m/s.
    public var jumpMinimumTakeoffSpeed: Double = 3.0

    /// How much quieter than the session's own median the accelerometer has to
    /// go before the rider counts as gliding rather than working.
    ///
    /// Relative, for the same reason the glide speed floor is. Vertical
    /// acceleration depends on the board, the chop, and where the device is
    /// strapped — a phone in a buoyancy vest reads nothing like a watch on a
    /// wrist. An absolute bar of 0.9 m/s² was tuned on a quiet SUP session and
    /// found *zero* glides in a real parawing run down the Columbia whose
    /// median was 1.86: the whole session was above the line, so nothing in it
    /// could ever be a glide.
    public var pumpEnergyFraction: Double = 1.5

    /// The smoothness bar may rise to this multiple of the session's own median
    /// vertical acceleration, but never fall below `foilSmoothnessSD`.
    ///
    /// Only ever loosens, which is the safe direction: speed is the primary
    /// test for flight and smoothness is a veto against being fast but still
    /// in the water. A veto tuned on a quiet rig turns into a blanket ban on a
    /// noisy one — a parawing session with a median of 1.86 against a bar of
    /// 1.6 had more than half its samples ruled out of flying, which cut a
    /// continuous ride into seventeen flights with sixteen "touchdowns", none
    /// of which dropped below 8 knots.
    public var foilSmoothnessFraction: Double = 1.5

    /// The shortest gap between two flights that could really have been a
    /// fall, in seconds.
    ///
    /// Not a property of the trace — a property of the rider. Falling off,
    /// coming up for air, swimming to the board, getting the wing or the
    /// handle back and pumping onto the foil is not a two-second job. Under
    /// this, two flights are one flight with a dip in it, whatever the speed
    /// did. A rider put the number at twenty to thirty seconds; twenty is the
    /// generous end of what they said, so the join only ever claims what they
    /// would claim.
    ///
    /// Per sport because relaunching differs: a kite has to be relaunched off
    /// the water and a windsurfer has to uphaul, both of which take longer
    /// than climbing back onto a foil board.
    public var foilMinimumRecovery: TimeInterval = 20

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

    /// A rider's own adjustments to a sport's defaults.
    ///
    /// The defaults are averages, and the things they average over — board,
    /// wing, foil, rider weight — vary more between two people on the same
    /// discipline than between two disciplines. A 90 kg rider on a small front
    /// wing does not take off where the wingfoil default says, so their "time
    /// on foil" is a number about openWater's assumptions rather than about
    /// their session.
    ///
    /// Every field is optional and nil means "use the default", so a rider who
    /// changes one thing is not silently opted out of improvements to the rest.
    public struct Overrides: Hashable, Sendable, Codable {

        /// Speed at or above which this rider is flying, m/s.
        public var foilTakeoffSpeed: Double?

        /// Speed at or above which they count as moving, m/s. Everything
        /// below it is "stopped", which sets moving time and the averages.
        public var movingSpeed: Double?

        /// Degrees of heading change that counts as a turn.
        public var maneuverHeadingChange: Double?

        /// What counts as a glide — see the matching fields on
        /// `SportThresholds`. Adjustable because the honest answer to "was that
        /// a glide?" varies with the rider, the gear and the water: a big board
        /// in small swell holds a glide at a speed a race foil would call
        /// slogging, and a river with current moves every ground speed.
        public var glideMinimumDuration: TimeInterval?
        public var glideDownwindAngle: Double?
        public var glideSpeedFraction: Double?
        public var glideMinimumGain: Double?

        /// What counts as a wave ride — see the matching fields on
        /// `SportThresholds`. Set from the wave rules on the Wave Rides
        /// screen, where a rider is looking at the rides these produced.
        public var waveConeAngle: Double?
        public var waveSpeedFraction: Double?
        public var waveMinimumGain: Double?
        public var waveMinimumDuration: TimeInterval?
        public var waveBridgeSeconds: TimeInterval?
        public var waveQuietFraction: Double?

        /// What counts as an upwind leg — see the matching fields on
        /// `SportThresholds`.
        public var upwindLegAngle: Double?
        public var upwindLegMinimumDistance: Double?
        public var upwindLegMinimumDuration: TimeInterval?

        /// What counts as a jump — see the matching fields on
        /// `SportThresholds`.
        public var jumpMinimumAirtime: TimeInterval?
        public var jumpFreeFall: Double?
        public var jumpLandingSpike: Double?
        public var jumpMinimumTakeoffSpeed: Double?

        /// See `SportThresholds.pumpEnergyFraction`.
        public var pumpEnergyFraction: Double?
        public var foilSmoothnessFraction: Double?

        public init(
            foilTakeoffSpeed: Double? = nil,
            movingSpeed: Double? = nil,
            maneuverHeadingChange: Double? = nil,
            glideMinimumDuration: TimeInterval? = nil,
            glideDownwindAngle: Double? = nil,
            glideSpeedFraction: Double? = nil,
            glideMinimumGain: Double? = nil,
            waveConeAngle: Double? = nil,
            waveSpeedFraction: Double? = nil,
            waveMinimumGain: Double? = nil,
            waveMinimumDuration: TimeInterval? = nil,
            waveBridgeSeconds: TimeInterval? = nil,
            waveQuietFraction: Double? = nil,
            upwindLegAngle: Double? = nil,
            upwindLegMinimumDistance: Double? = nil,
            upwindLegMinimumDuration: TimeInterval? = nil,
            jumpMinimumAirtime: TimeInterval? = nil,
            jumpFreeFall: Double? = nil,
            jumpLandingSpike: Double? = nil,
            jumpMinimumTakeoffSpeed: Double? = nil,
            pumpEnergyFraction: Double? = nil,
            foilSmoothnessFraction: Double? = nil
        ) {
            self.foilTakeoffSpeed = foilTakeoffSpeed
            self.movingSpeed = movingSpeed
            self.maneuverHeadingChange = maneuverHeadingChange
            self.glideMinimumDuration = glideMinimumDuration
            self.glideDownwindAngle = glideDownwindAngle
            self.glideSpeedFraction = glideSpeedFraction
            self.glideMinimumGain = glideMinimumGain
            self.waveConeAngle = waveConeAngle
            self.waveSpeedFraction = waveSpeedFraction
            self.waveMinimumGain = waveMinimumGain
            self.waveMinimumDuration = waveMinimumDuration
            self.waveBridgeSeconds = waveBridgeSeconds
            self.waveQuietFraction = waveQuietFraction
            self.upwindLegAngle = upwindLegAngle
            self.upwindLegMinimumDistance = upwindLegMinimumDistance
            self.upwindLegMinimumDuration = upwindLegMinimumDuration
            self.jumpMinimumAirtime = jumpMinimumAirtime
            self.jumpFreeFall = jumpFreeFall
            self.jumpLandingSpike = jumpLandingSpike
            self.jumpMinimumTakeoffSpeed = jumpMinimumTakeoffSpeed
            self.pumpEnergyFraction = pumpEnergyFraction
            self.foilSmoothnessFraction = foilSmoothnessFraction
        }

        public var isEmpty: Bool {
            foilTakeoffSpeed == nil && movingSpeed == nil && maneuverHeadingChange == nil
                && glideMinimumDuration == nil && glideDownwindAngle == nil
                && glideSpeedFraction == nil && glideMinimumGain == nil
                && waveConeAngle == nil && waveSpeedFraction == nil
                && waveMinimumGain == nil && waveMinimumDuration == nil
                && waveBridgeSeconds == nil && waveQuietFraction == nil
                && upwindLegAngle == nil && upwindLegMinimumDistance == nil
                && upwindLegMinimumDuration == nil
                && jumpMinimumAirtime == nil && jumpFreeFall == nil
                && jumpLandingSpike == nil && jumpMinimumTakeoffSpeed == nil
                && pumpEnergyFraction == nil && foilSmoothnessFraction == nil
        }

        public func applied(to base: SportThresholds) -> SportThresholds {
            var t = base
            if let v = foilTakeoffSpeed, v > 0 { t.foilTakeoffSpeed = v }
            if let v = movingSpeed, v > 0 { t.movingSpeed = v }
            if let v = maneuverHeadingChange, v > 0 { t.maneuverHeadingChange = v }
            if let v = glideMinimumDuration, v > 0 { t.glideMinimumDuration = v }
            if let v = glideDownwindAngle, v > 0 { t.glideDownwindAngle = v }
            if let v = glideSpeedFraction, v > 0 { t.glideSpeedFraction = v }
            if let v = glideMinimumGain, v >= 0 { t.glideMinimumGain = v }
            // The wave rules pass their zeros through: a rider who says a
            // wave has to add nothing, or that no carve is bridged, means it.
            if let v = waveConeAngle, v > 0 { t.waveConeAngle = v }
            if let v = waveSpeedFraction, v > 0 { t.waveSpeedFraction = v }
            if let v = waveMinimumGain, v >= 0 { t.waveMinimumGain = v }
            if let v = waveMinimumDuration, v > 0 { t.waveMinimumDuration = v }
            if let v = waveBridgeSeconds, v >= 0 { t.waveBridgeSeconds = v }
            if let v = waveQuietFraction, v > 0 { t.waveQuietFraction = v }
            if let v = upwindLegAngle, v > 0 { t.upwindLegAngle = v }
            if let v = upwindLegMinimumDistance, v > 0 { t.upwindLegMinimumDistance = v }
            if let v = upwindLegMinimumDuration, v > 0 { t.upwindLegMinimumDuration = v }
            if let v = jumpMinimumAirtime, v > 0 { t.jumpMinimumAirtime = v }
            if let v = jumpFreeFall, v > 0 { t.jumpFreeFall = v }
            if let v = jumpLandingSpike, v > 0 { t.jumpLandingSpike = v }
            if let v = jumpMinimumTakeoffSpeed, v > 0 { t.jumpMinimumTakeoffSpeed = v }
            if let v = pumpEnergyFraction, v > 0 { t.pumpEnergyFraction = v }
            if let v = foilSmoothnessFraction, v > 0 { t.foilSmoothnessFraction = v }
            return t
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
