import Foundation

/// Where a track can honestly be drawn as a line, and where it cannot.
///
/// Every map in the app used to hand MapKit the whole point list as one
/// polyline. Between two fixes that is a line, and between two fixes forty
/// minutes apart it is still a line — a straight one, across water nobody was
/// recorded on. A rider whose receiver went quiet, or whose recording was
/// paused, got a map with a ruler drawn across it, and read it as a track.
///
/// The distance maths already refuses to count a leg like that. Drawing has to
/// refuse it too, and this is where the two agree on what "like that" means.
extension Track {

    /// A hole longer than this is drawn as a hole.
    ///
    /// Shorter than the ten minutes `TrackBuilder` will still bridge for
    /// distance, on purpose. A quiet receiver over a drifting rider is nearly
    /// stationary, so its straight line is nearly the truth and is worth its
    /// few metres of distance — but at riding speed thirty seconds is a
    /// quarter of a kilometre, and a line that long through open water is a
    /// claim about where the rider went. Below it a gap is a wobble; above it
    /// the honest picture is two ends and nothing between.
    public static let drawableGap: TimeInterval = 30

    /// Runs of consecutive fixes with no hole longer than `maxGap` between
    /// them, as index ranges into `points`. Covers every index exactly once.
    public func contiguousRanges(maxGap: TimeInterval = Track.drawableGap) -> [ClosedRange<Int>] {
        elapsed.contiguousRanges(maxGap: maxGap)
    }

    /// `range` cut wherever a hole longer than `maxGap` falls inside it.
    public func contiguousRanges(
        in range: ClosedRange<Int>,
        maxGap: TimeInterval = Track.drawableGap
    ) -> [ClosedRange<Int>] {
        guard !elapsed.isEmpty else { return [] }
        let lower = max(0, range.lowerBound)
        let upper = min(elapsed.count - 1, range.upperBound)
        guard lower <= upper else { return [] }
        return Array(elapsed[lower...upper]).contiguousRanges(maxGap: maxGap).map {
            ($0.lowerBound + lower)...($0.upperBound + lower)
        }
    }
}

extension Array where Element == TrackPoint {

    /// The same split, for a point list that has not been built into a track
    /// yet — the live map draws from the recorder's raw fixes.
    public func contiguousRanges(maxGap: TimeInterval = Track.drawableGap) -> [ClosedRange<Int>] {
        guard let first else { return [] }
        return map { $0.timestamp.timeIntervalSince(first.timestamp) }.contiguousRanges(maxGap: maxGap)
    }
}

extension Array where Element == TimeInterval {

    /// Index ranges between which no two neighbours are more than `maxGap`
    /// apart. Every index lands in exactly one range; a lone fix is a range of
    /// one, which the caller will not be able to draw and can skip.
    func contiguousRanges(maxGap: TimeInterval) -> [ClosedRange<Int>] {
        guard !isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = 0
        for i in 1..<count where self[i] - self[i - 1] > maxGap {
            ranges.append(start...(i - 1))
            start = i
        }
        ranges.append(start...(count - 1))
        return ranges
    }
}
