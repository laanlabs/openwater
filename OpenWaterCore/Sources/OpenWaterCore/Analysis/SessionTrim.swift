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

    /// Stretches cut out of the middle.
    ///
    /// Trimming the ends is the common case, but not the only one: a rider
    /// stops for twenty minutes to help someone, or the drive home gets
    /// recorded because they forgot to stop. That is not the start or the end,
    /// and cutting it needs the same guarantee as trimming — stored as ranges,
    /// never applied by deleting fixes.
    ///
    /// Optional rather than an empty array on purpose. Swift's synthesized
    /// decoder does not fall back to a property's default when a key is absent,
    /// so a non-optional here would fail to decode every session written before
    /// this existed — which is every session anybody currently has.
    public var removals: [Removal]?

    /// One cut, in the recording's own clock.
    ///
    /// A struct rather than a `ClosedRange` because a range whose lower bound
    /// exceeds its upper bound traps at construction, and these are built from
    /// dragged handles.
    public struct Removal: Hashable, Sendable, Codable, Identifiable {
        public var start: TimeInterval
        public var end: TimeInterval

        public var id: String { "\(start)-\(end)" }
        public var duration: TimeInterval { max(0, end - start) }

        public init(start: TimeInterval, end: TimeInterval) {
            self.start = min(start, end)
            self.end = max(start, end)
        }

        public func contains(_ offset: TimeInterval) -> Bool {
            offset >= start && offset <= end
        }
    }

    public init(
        startOffset: TimeInterval = 0,
        endOffset: TimeInterval? = nil,
        removals: [Removal]? = nil
    ) {
        self.startOffset = max(0, startOffset)
        self.endOffset = endOffset
        self.removals = (removals?.isEmpty ?? true) ? nil : removals
    }

    /// No trim — the whole recording.
    public static let none = SessionTrim()

    /// Whether the session differs from the recording in any way — which is
    /// what decides that the original has to be kept alongside it.
    public var isTrimmed: Bool {
        startOffset > 0.5 || endOffset != nil || !(removals?.isEmpty ?? true)
    }

    /// Cuts taken out of the middle, in order.
    public var cuts: [Removal] { (removals ?? []).sorted { $0.start < $1.start } }

    /// Total time removed from the middle.
    public var removedDuration: TimeInterval {
        cuts.reduce(0) { $0 + $1.duration }
    }

    /// Compose a selection made on an already-trimmed timeline.
    ///
    /// A trim's offsets are measured from the start of the *recording*, but a
    /// rider trimming a second time is looking at the trimmed session — their
    /// 0:00 is this trim's `startOffset`. Feeding their numbers back in
    /// unconverted produces a range that can run clean off the end of the
    /// session; the UI showed "from 21:08 to 45:12 of 30:01" and drew one
    /// handle off the edge of the screen.
    ///
    /// - Parameters:
    ///   - start: seconds from the start of the *visible* session.
    ///   - end: seconds from the start of the visible session, or `nil` to keep
    ///     whatever this trim already ends at — usually "to the end", which must
    ///     not silently become a fixed timestamp.
    public func narrowed(start: TimeInterval, end: TimeInterval?) -> SessionTrim {
        SessionTrim(
            startOffset: startOffset + max(0, start),
            endOffset: end.map { startOffset + max(0, $0) } ?? endOffset,
            removals: removals
        )
    }

    /// Add a cut selected on the *visible* timeline.
    ///
    /// Same conversion as `narrowed`, and for the same reason: the rider's 0:00
    /// is this trim's start, and a cut recorded in their clock would land
    /// somewhere else entirely in the recording's.
    ///
    /// The offsets are the visible clock *before* any earlier cut is applied,
    /// which is what the trim bar shows — it draws the session as it currently
    /// stands, cuts included.
    public func removing(start: TimeInterval, end: TimeInterval) -> SessionTrim {
        var result = self
        var cuts = self.cuts
        cuts.append(Removal(start: startOffset + max(0, start), end: startOffset + max(0, end)))
        result.removals = SessionTrim.merge(cuts)
        return result
    }

    /// Overlapping or touching cuts become one, so removing the same stretch
    /// twice cannot produce a list that grows without bound.
    static func merge(_ cuts: [Removal]) -> [Removal] {
        let sorted = cuts.sorted { $0.start < $1.start }
        var merged: [Removal] = []
        for cut in sorted {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1] = Removal(start: last.start, end: max(last.end, cut.end))
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    /// Points falling inside the trim.
    public func apply(to points: [TrackPoint]) -> [TrackPoint] {
        guard let first = points.first else { return points }
        let origin = first.timestamp
        let lower = origin.addingTimeInterval(startOffset)
        let upper = endOffset.map { origin.addingTimeInterval($0) }

        let cuts = self.cuts
        return points.filter { point in
            guard point.timestamp >= lower else { return false }
            if let upper, point.timestamp > upper { return false }
            if !cuts.isEmpty {
                let offset = point.timestamp.timeIntervalSince(origin)
                if cuts.contains(where: { $0.contains(offset) }) { return false }
            }
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

    /// A standalone copy with the edit baked in.
    ///
    /// "Save as new activity" means what it says: the original session is left
    /// exactly as it was, and the copy *is* the edited track — no trim, no
    /// second copy of the recording behind it. Keeping the original fixes on
    /// the duplicate would make the word "new" a lie and double the storage of
    /// every edit somebody keeps both ways.
    public func savedAsNewActivity(titled title: String? = nil) -> Session {
        var copy = self
        copy.id = UUID()
        copy.trim = .none
        copy.untrimmedPoints = nil
        copy.title = title ?? self.title.map { "\($0) (edited)" } ?? nil
        return copy
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
