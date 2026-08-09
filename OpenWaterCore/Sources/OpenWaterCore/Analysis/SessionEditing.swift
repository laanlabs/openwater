import Foundation

/// Changing a session's metadata after the fact.
///
/// Most edits are cosmetic — a title, a spot name, a note — and touch nothing
/// but the label. Two are not:
///
/// - **Sport** selects every detection threshold there is: takeoff speed, turn
///   sharpness, plausible maximum, whether flights are looked for at all. A
///   session recorded or imported as the wrong sport does not have slightly
///   wrong flights and gybes, it has meaningless ones.
/// - **Wind** is what true wind angle, VMG, the polar, and the tack-versus-gybe
///   classification are all derived from.
///
/// So those two edits re-run the analysis, and the rest do not. Getting that
/// distinction wrong in either direction is bad: recomputing on every keystroke
/// of a note would be slow, and *not* recomputing on a sport change would leave
/// a rider looking at numbers that quietly no longer mean anything.
extension Session {

    /// Fields a rider can change after a session is recorded.
    public struct Edits: Sendable, Equatable {
        public var sport: Sport
        public var title: String?
        public var spotName: String?
        public var notes: String
        /// Why the rider went out, free text.
        public var purpose: String?
        /// How it felt, 1-5. `nil` means not recorded.
        public var feeling: Int?
        /// Flying threshold in m/s; `nil` keeps the sport default.
        public var foilTakeoffSpeed: Double?
        /// Wind direction the rider is asserting, in degrees the wind comes
        /// from. `nil` leaves whatever the estimator worked out.
        public var windDirection: Double?
        /// Wind speed in m/s, if known. Never inferred from a track.
        public var windSpeed: Double?
        /// Swell height in metres, if the rider called it.
        public var swellHeight: Double?
        /// Degrees the swell comes from, if the rider called it.
        public var swellDirection: Double?

        public init(
            sport: Sport,
            title: String? = nil,
            spotName: String? = nil,
            notes: String = "",
            purpose: String? = nil,
            feeling: Int? = nil,
            foilTakeoffSpeed: Double? = nil,
            windDirection: Double? = nil,
            windSpeed: Double? = nil,
            swellHeight: Double? = nil,
            swellDirection: Double? = nil
        ) {
            self.sport = sport
            self.title = title
            self.spotName = spotName
            self.notes = notes
            self.purpose = purpose
            self.feeling = feeling
            self.foilTakeoffSpeed = foilTakeoffSpeed
            self.windDirection = windDirection
            self.windSpeed = windSpeed
            self.swellHeight = swellHeight
            self.swellDirection = swellDirection
        }

        public init(session: Session) {
            self.sport = session.sport
            self.title = session.title
            self.spotName = session.spotName
            self.notes = session.notes
            self.purpose = session.purpose
            self.feeling = session.feeling
            self.foilTakeoffSpeed = session.foilTakeoffSpeed
            // Only pre-fill a direction the rider actually asserted. Showing an
            // estimate in an editable field turns it into a value they appear
            // to have entered, and the next save would promote a guess into a
            // stated fact.
            let wind = session.effectiveWind
            self.windDirection = wind?.source == .manual ? wind?.directionFrom : nil
            self.windSpeed = wind?.speed
            self.swellHeight = session.swellHeight
            self.swellDirection = session.swellDirection
        }
    }

    /// Whether applying these edits requires the analysis to be re-run.
    public func requiresReanalysis(for edits: Edits) -> Bool {
        if edits.sport != sport { return true }
        // The flying threshold is not cosmetic: flights, time on foil, distance
        // on foil and the longest segment are all counted from it.
        if edits.foilTakeoffSpeed != foilTakeoffSpeed { return true }

        let current = effectiveWind
        let currentManual = current?.source == .manual ? current?.directionFrom : nil
        if edits.windDirection != currentManual { return true }
        if edits.windSpeed != current?.speed { return true }

        return false
    }

    /// Apply edits, recomputing the analysis only when something changed that
    /// the numbers actually depend on.
    public func applying(
        _ edits: Edits,
        categories: [SpeedCategory] = SpeedCategory.all,
        overrides: SportThresholds.Overrides? = nil
    ) -> Session {
        var result = self
        result.title = edits.title?.trimmedOrNil
        result.spotName = edits.spotName?.trimmedOrNil
        result.notes = edits.notes
        result.purpose = edits.purpose?.trimmedOrNil
        result.feeling = edits.feeling
        result.swellHeight = edits.swellHeight
        result.swellDirection = edits.swellDirection

        guard requiresReanalysis(for: edits) else { return result }

        result.sport = edits.sport
        result.foilTakeoffSpeed = edits.foilTakeoffSpeed

        let wind: Wind? = edits.windDirection.map {
            Wind(directionFrom: $0, speed: edits.windSpeed, source: .manual, confidence: 1)
        }

        // The track itself is rebuilt too, not just re-analysed: the ingest
        // filters are sport-specific as well, so a windsurf session reclassified
        // as a kayak should have its implausible-speed ceiling change with it.
        let track = TrackBuilder(options: .forSport(edits.sport)).build(from: self.track.points)
        let summary = SessionAnalyzer(
            configuration: .init(
                sport: edits.sport,
                categories: categories,
                wind: wind,
                foilTakeoffSpeed: edits.foilTakeoffSpeed,
                overrides: overrides
            )
        ).analyse(track)

        result.track = track
        result.wind = summary.wind
        result.summary = summary
        return result
    }
}

extension String {
    /// The string with whitespace trimmed, or `nil` when nothing is left.
    ///
    /// Optional-but-empty and optional-and-absent should not be two different
    /// states for a text field — a rider who clears a title means it has none.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
