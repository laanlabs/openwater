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
        /// Wind direction the rider is asserting, in degrees the wind comes
        /// from. `nil` leaves whatever the estimator worked out.
        public var windDirection: Double?
        /// Wind speed in m/s, if known. Never inferred from a track.
        public var windSpeed: Double?

        public init(
            sport: Sport,
            title: String? = nil,
            spotName: String? = nil,
            notes: String = "",
            windDirection: Double? = nil,
            windSpeed: Double? = nil
        ) {
            self.sport = sport
            self.title = title
            self.spotName = spotName
            self.notes = notes
            self.windDirection = windDirection
            self.windSpeed = windSpeed
        }

        public init(session: Session) {
            self.sport = session.sport
            self.title = session.title
            self.spotName = session.spotName
            self.notes = session.notes
            // Only pre-fill a direction the rider actually asserted. Showing an
            // estimate in an editable field turns it into a value they appear
            // to have entered, and the next save would promote a guess into a
            // stated fact.
            let wind = session.effectiveWind
            self.windDirection = wind?.source == .manual ? wind?.directionFrom : nil
            self.windSpeed = wind?.speed
        }
    }

    /// Whether applying these edits requires the analysis to be re-run.
    public func requiresReanalysis(for edits: Edits) -> Bool {
        if edits.sport != sport { return true }

        let current = effectiveWind
        let currentManual = current?.source == .manual ? current?.directionFrom : nil
        if edits.windDirection != currentManual { return true }
        if edits.windSpeed != current?.speed { return true }

        return false
    }

    /// Apply edits, recomputing the analysis only when something changed that
    /// the numbers actually depend on.
    public func applying(_ edits: Edits, categories: [SpeedCategory] = SpeedCategory.all) -> Session {
        var result = self
        result.title = edits.title?.trimmedOrNil
        result.spotName = edits.spotName?.trimmedOrNil
        result.notes = edits.notes

        guard requiresReanalysis(for: edits) else { return result }

        result.sport = edits.sport

        let wind: Wind? = edits.windDirection.map {
            Wind(directionFrom: $0, speed: edits.windSpeed, source: .manual, confidence: 1)
        }

        // The track itself is rebuilt too, not just re-analysed: the ingest
        // filters are sport-specific as well, so a windsurf session reclassified
        // as a kayak should have its implausible-speed ceiling change with it.
        let track = TrackBuilder(options: .forSport(edits.sport)).build(from: self.track.points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: edits.sport, categories: categories, wind: wind)
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
