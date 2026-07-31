import Foundation

/// Which part of a recording counts as the session.
///
/// A recording almost never starts and ends exactly where the riding does.
/// People hit record on the beach and rig up, paddle out, sit talking to
/// somebody for ten minutes, come in, and forget to stop until they are back at
/// the car. All of that lands in the averages: moving time, distance and every
/// windowed metric are dragged down by time that was never sailing.
///
/// The fix is emphatically **not** to drop it while recording. A rider taking a
/// break in the water is still doing the session, and an auto-pause that
/// misfires mid-run corrupts exactly the numbers people care about — worse, it
/// throws data away that can never be recovered. So openWater records
/// everything and lets the boundaries be moved afterwards.
///
/// The trim is stored as a *range*, not applied by deleting points. Every
/// original fix stays in the archive, so a trim can be widened again, undone
/// entirely, or ignored by anything reading the raw data. Nothing is lost.
public struct SessionTrim: Hashable, Sendable, Codable {

    /// Seconds from the start of the recording where the session begins.
    public var startOffset: TimeInterval

    /// Seconds from the *start of the recording* where the session ends.
    /// `nil` means "to the end".
    public var endOffset: TimeInterval?

    public init(startOffset: TimeInterval = 0, endOffset: TimeInterval? = nil) {
        self.startOffset = max(0, startOffset)
        self.endOffset = endOffset
    }

    /// No trim — the whole recording.
    public static let none = SessionTrim()

    public var isTrimmed: Bool {
        startOffset > 0.5 || endOffset != nil
    }

    /// Points falling inside the trim.
    public func apply(to points: [TrackPoint]) -> [TrackPoint] {
        guard let first = points.first else { return points }
        let origin = first.timestamp
        let lower = origin.addingTimeInterval(startOffset)
        let upper = endOffset.map { origin.addingTimeInterval($0) }

        return points.filter { point in
            guard point.timestamp >= lower else { return false }
            if let upper, point.timestamp > upper { return false }
            return true
        }
    }
}

extension Session {

    /// Apply a trim, recomputing everything from the surviving fixes.
    ///
    /// The full point list is kept on the returned session, so this is
    /// reversible: trimming to the middle ten minutes and then back to the whole
    /// recording restores the original numbers exactly.
    public func trimmed(
        to trim: SessionTrim,
        categories: [SpeedCategory] = SpeedCategory.all
    ) -> Session {
        var result = self
        let original = rawPoints
        result.trim = trim
        // Hold on to the full recording so the trim can be widened or undone.
        // Dropped again when there is no trim, so an untrimmed session never
        // carries two copies of its own track.
        result.untrimmedPoints = trim.isTrimmed ? original : nil

        let points = trim.apply(to: original)
        guard points.count >= 2 else { return result }

        let track = TrackBuilder(options: .forSport(sport)).build(from: points)
        let summary = SessionAnalyzer(
            configuration: .init(sport: sport, categories: categories, wind: effectiveWind)
        ).analyse(track)

        result.track = track
        result.summary = summary
        result.startDate = track.startDate ?? startDate
        result.endDate = track.endDate ?? endDate
        return result
    }

    /// Suggest a trim that removes the dead time at each end.
    ///
    /// Only ever *offered*, never applied automatically — a rider who genuinely
    /// spent the first ten minutes drifting deserves to see that in their
    /// session if they want to. It looks for the first and last moment the
    /// rider was actually moving, and backs off a little so nothing real is cut.
    public func suggestedTrim(padding: TimeInterval = 15) -> SessionTrim? {
        let threshold = sport.thresholds.movingSpeed
        let track = self.track
        guard track.count > 2 else { return nil }

        guard let firstMoving = track.speed.firstIndex(where: { $0 >= threshold }),
              let lastMoving = track.speed.lastIndex(where: { $0 >= threshold }),
              lastMoving > firstMoving else { return nil }

        let start = max(0, track.elapsed[firstMoving] - padding)
        let end = min(track.duration, track.elapsed[lastMoving] + padding)

        // Not worth offering to shave a few seconds off.
        guard start > 30 || (track.duration - end) > 30 else { return nil }

        return SessionTrim(
            startOffset: start,
            endOffset: end < track.duration - 1 ? end : nil
        )
    }
}
