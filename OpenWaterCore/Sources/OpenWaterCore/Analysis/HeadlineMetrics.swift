import Foundation

/// Which four numbers a session leads with.
///
/// Three of them never change — top speed, distance, duration are what anyone
/// asks about any session in any sport. The fourth is the one that says what
/// kind of session it *was*, and it is the only one worth choosing: a foiler
/// quotes time on foil, a downwinder quotes time gliding, and a kayaker
/// quotes neither.
///
/// The rule is deliberately split in two. The **sport** decides which measure
/// would be preferred if it existed; the **data** decides whether it exists.
/// That way a wingfoiler who did a downwinder still leads with foil time —
/// which is what they would say out loud — while a downwind SUP that happened
/// to trip the flight detector still leads with glides.
public enum HeadlineMetrics {

    /// The fourth headline tile.
    public enum Slot: String, Hashable, Sendable, Codable, CaseIterable {

        /// Total seconds flying, from `FoilSummary.timeOnFoil`.
        case timeOnFoil

        /// Total seconds on swell, from `DownwindSummary.glideTime`.
        case timeGliding

        /// Distance ÷ moving time, from `SessionSummary.averageMovingSpeed`.
        case averageMovingSpeed

        /// The tile's label. The value's formatting stays with the app, which
        /// owns the rider's unit preference.
        public var title: String {
            switch self {
            case .timeOnFoil: "Time on foil"
            case .timeGliding: "Time gliding"
            case .averageMovingSpeed: "Avg moving"
            }
        }
    }

    /// The fourth tile for this session, given the sport it was ridden in and
    /// what the analysis actually found.
    public static func slot(for sport: Sport, summary: SessionSummary) -> Slot {
        for candidate in preference(for: sport) where isAvailable(candidate, in: summary) {
            return candidate
        }
        return .averageMovingSpeed
    }

    /// Which measure the discipline would rather lead with.
    ///
    /// Swell-riding sports put glides first: on a downwinder the flights are
    /// incidental to the bumps, and a rider describes the day by how much of
    /// it they spent gliding. Everything else puts flight time first, because
    /// where foiling happens at all it is the thing being practised.
    static func preference(for sport: Sport) -> [Slot] {
        if sport.ridesSwell {
            return [.timeGliding, .timeOnFoil, .averageMovingSpeed]
        }
        return [.timeOnFoil, .timeGliding, .averageMovingSpeed]
    }

    /// Whether the session found enough of this to be worth a headline tile.
    ///
    /// A single detected flight in an hour of paddling is a detector artefact,
    /// not a headline — but the threshold stays at "any", because raising it
    /// would mean a genuine one-flight session silently reported nothing. The
    /// per-detection confidence is shown on the Foiling screen instead.
    static func isAvailable(_ slot: Slot, in summary: SessionSummary) -> Bool {
        switch slot {
        case .timeOnFoil: summary.foil.flightCount > 0 && summary.foil.timeOnFoil > 0
        case .timeGliding: summary.downwind.glideCount > 0 && summary.downwind.glideTime > 0
        case .averageMovingSpeed: true
        }
    }
}

extension Sport {

    /// Sports whose point is catching swell rather than holding a line — the
    /// ones a rider describes by how much of the session they spent gliding.
    public var ridesSwell: Bool {
        switch self {
        case .downwindSUP, .sup, .prone:
            true
        case .wingfoil, .parawing, .windsurf, .windfoil, .kitesurf, .kitefoil,
             .sail, .kayak, .efoil, .tow, .other:
            false
        }
    }
}
