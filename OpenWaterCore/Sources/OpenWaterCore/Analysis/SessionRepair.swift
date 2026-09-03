import Foundation

/// Repairs for recordings the receiver got wrong.
///
/// Two different problems, deliberately given two different mechanisms:
///
/// **Spikes** are fixes that are simply false — the antenna went under, the
/// receiver reacquired, and for a second the rider "was" forty metres to the
/// side. Those are garbage, not data, so they are removed outright — but only
/// ever on a *duplicate*, so the original recording stays exactly as the
/// receiver wrote it.
///
/// **Removing the max speed** is a judgement, not a repair: the rider looking
/// at a 32-knot personal best they know they did not do. That cut is stored as
/// a `SessionTrim.Removal` — the same reversible mechanism as any other trim —
/// so nothing is deleted and Restore Full Recording gives the number back.
public struct SpikeScrub: Sendable {

    /// How many times to sweep. A two-sample excursion looks like one bad fix
    /// only after its neighbour has gone, so single-pass cleaning misses every
    /// spike wider than one sample. Each pass can only shrink the track, so
    /// this converges; the cap is for pathological input.
    public var passes: Int

    /// How much faster than the detour-free path a fix has to imply travel
    /// before it is a spike. 1.0 would flag honest corners; this is the margin
    /// that keeps real riding safe.
    public var factor: Double

    /// Implied speeds below this are never spikes, m/s. Moored-boat jitter
    /// zig-zags exactly like a spike field, and none of it matters.
    public var floor: Double

    public init(passes: Int = 4, factor: Double = 2.5, floor: Double = 4.0) {
        self.passes = passes
        self.factor = factor
        self.floor = floor
    }

    /// Longest excursion the out-and-back test looks for, in samples. A spike
    /// is rarely one fix: the receiver that lost the plot usually needs two or
    /// three to find it again, and a displaced *plateau* fools any single-fix
    /// test — the leg between two equally wrong fixes looks perfectly calm.
    public var maxWidth: Int = 3

    /// The same points minus the excursions that fail the out-and-back test.
    ///
    /// A spike has a signature no honest manoeuvre shares: the path sprints
    /// away from the line and straight back, so the legs into and out of the
    /// excursion both imply speeds far above the speed of the path that skips
    /// it. A real gybe turns *through* a corner — skipping its apex still
    /// implies most of the same speed.
    ///
    /// Worth knowing what this is *for*: `TrackBuilder` already rejects any
    /// fix implying more than the sport's plausible maximum, and on a track
    /// with a Doppler channel the speed figures never trusted positions
    /// anyway. The scrub earns its keep on what gets past both — moderate
    /// spikes under the plausibility ceiling, and imported GPX with no speed
    /// channel, where position is all there is.
    public func clean(_ points: [TrackPoint]) -> (points: [TrackPoint], removed: Int) {
        var kept = points
        var removedTotal = 0

        for _ in 0..<passes {
            guard kept.count >= 3 else { break }
            var spiked = Set<Int>()

            var i = 1
            scan: while i < kept.count - 1 {
                for w in 1...maxWidth where i + w < kept.count {
                    let a = kept[i - 1]
                    let first = kept[i], last = kept[i + w - 1]
                    let c = kept[i + w]
                    let dtIn = first.timestamp.timeIntervalSince(a.timestamp)
                    let dtOut = c.timestamp.timeIntervalSince(last.timestamp)
                    let dtSkip = c.timestamp.timeIntervalSince(a.timestamp)
                    guard dtIn > 0, dtOut > 0, dtSkip > 0 else { continue }

                    let vIn = Geo.distance(a.coordinate, first.coordinate) / dtIn
                    let vOut = Geo.distance(last.coordinate, c.coordinate) / dtOut
                    let vSkip = Geo.distance(a.coordinate, c.coordinate) / dtSkip

                    let threshold = max(floor, vSkip * factor)
                    guard vIn > threshold, vOut > threshold else { continue }

                    // A fix whose own Doppler agrees with the implied sprint
                    // was genuinely moving that fast — not ours to delete.
                    // Only when the speed channel contradicts the jump (or is
                    // absent) is the position the liar.
                    let protected = (i..<(i + w)).contains { j in
                        guard let reported = kept[j].speed, kept[j].hasValidSpeed else { return false }
                        return reported > min(vIn, vOut) * 0.7
                    }
                    guard !protected else { continue }

                    for j in i..<(i + w) { spiked.insert(j) }
                    i += w + 1
                    continue scan
                }
                i += 1
            }

            guard !spiked.isEmpty else { break }
            removedTotal += spiked.count
            kept = kept.enumerated().compactMap { spiked.contains($0.offset) ? nil : $0.element }
        }
        return (kept, removedTotal)
    }
}

extension Session {

    /// A new, independent session that is this one with its spikes removed.
    ///
    /// A duplicate rather than an edit, on both of Waterspeed's precedents and
    /// our own principle: the scrub is a heuristic, and a heuristic should
    /// never be the only copy of anything. The duplicate follows
    /// `savedAsNewActivity` semantics — the current trimmed view is what gets
    /// cleaned and baked in, with no second copy of the recording behind it.
    public func duplicatedRemovingSpikes(
        titled title: String? = nil,
        scrub: SpikeScrub = SpikeScrub(),
        categories: [SpeedCategory] = SpeedCategory.all,
        overrides: SportThresholds.Overrides? = nil
    ) -> (session: Session, removedFixes: Int) {
        let (cleaned, removed) = scrub.clean(track.points)

        var copy = self
        copy.id = UUID()
        copy.trim = .none
        copy.untrimmedPoints = nil
        copy.title = title ?? self.title.map { "\($0) (de-spiked)" } ?? "De-spiked copy"

        guard cleaned.count >= 2 else { return (copy, removed) }

        let track = TrackBuilder(options: trackBuilderOptions).build(from: cleaned)
        copy.track = track
        copy.summary = SessionAnalyzer(
            configuration: .init(
                sport: sport, categories: categories, wind: effectiveWind,
                foilTakeoffSpeed: foilTakeoffSpeed, overrides: overrides
            )
        ).analyse(track)
        copy.startDate = track.startDate ?? startDate
        copy.endDate = track.endDate ?? endDate
        return (copy, removed)
    }

    /// An exact copy under a new identity.
    public func duplicated(titled title: String? = nil) -> Session {
        var copy = self
        copy.id = UUID()
        copy.title = title ?? self.title.map { "\($0) (copy)" } ?? "Copy"
        return copy
    }

    /// The session with the stretch responsible for its current max cut out,
    /// as a reversible trim removal.
    ///
    /// Cuts the contiguous run around the peak still travelling at ≥90% of it,
    /// padded a little so the ramp the bad fix smeared into its neighbours
    /// goes with it. Everything downstream — new max, windows, runs, polar —
    /// falls out of the normal re-analysis. Returns nil when there is nothing
    /// to cut, or when cutting it would leave no session.
    public func removingMaxSpeed(
        padding: TimeInterval = 1.5,
        categories: [SpeedCategory] = SpeedCategory.all,
        overrides: SportThresholds.Overrides? = nil
    ) -> (session: Session, previousMax: Double, newMax: Double)? {
        guard track.count >= 3,
              let peakIndex = track.speed.indices.max(by: { track.speed[$0] < track.speed[$1] })
        else { return nil }
        let peak = track.speed[peakIndex]
        guard peak > 0 else { return nil }

        var lo = peakIndex, hi = peakIndex
        while lo > 0, track.speed[lo - 1] >= peak * 0.9 { lo -= 1 }
        while hi < track.count - 1, track.speed[hi + 1] >= peak * 0.9 { hi += 1 }

        // Offsets are in the recording's own clock — the raw start — because
        // that is the clock every other removal and the trim handles use.
        guard let rawStart = rawPoints.first?.timestamp else { return nil }
        let cutStart = track.points[lo].timestamp.timeIntervalSince(rawStart) - padding
        let cutEnd = track.points[hi].timestamp.timeIntervalSince(rawStart) + padding

        var newTrim = trim
        var removals = newTrim.removals ?? []
        removals.append(.init(start: cutStart, end: cutEnd))
        newTrim.removals = removals

        let repaired = trimmed(to: newTrim, categories: categories, overrides: overrides)
        guard repaired.track.count >= 2 else { return nil }
        return (repaired, peak, repaired.track.speed.max() ?? 0)
    }
}
