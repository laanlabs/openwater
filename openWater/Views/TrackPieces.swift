import CoreLocation
import OpenWaterCore

/// The track as MapKit should be handed it: in pieces, one per stretch the
/// receiver was actually reporting.
///
/// A polyline joins its points, and it has no way to know that two of them
/// are forty minutes apart. Every map in the app used to give it the whole
/// track and get back a straight ruler across each hole in the recording —
/// which a rider reads as the path they took, and cannot tell from the real
/// thing. The split lives in `Track.contiguousRanges`; this is the bridge to
/// coordinates, so each map has one line to change.
extension Track {

    /// Every drawable stretch of the whole track.
    var polylinePieces: [[CLLocationCoordinate2D]] {
        contiguousRanges().compactMap(polyline(in:))
    }

    /// The drawable stretches inside an index range — a run, a leg, a
    /// segment — cut wherever the recording has a hole.
    func polylinePieces(in range: ClosedRange<Int>) -> [[CLLocationCoordinate2D]] {
        contiguousRanges(in: range).compactMap(polyline(in:))
    }

    /// One piece, or nothing for a lone fix that no line can be drawn through.
    private func polyline(in range: ClosedRange<Int>) -> [CLLocationCoordinate2D]? {
        guard range.count > 1 else { return nil }
        return points[range].map(\.clCoordinate)
    }
}

extension Array where Element == TrackPoint {

    /// The same for raw fixes, thinned to about `budget` points for a map
    /// that is redrawn on every one of them. Thinned *within* each piece:
    /// thinning first and splitting after would let a stride step clean over
    /// a hole and stitch it shut again.
    func polylinePieces(budget: Int = 400) -> [[CLLocationCoordinate2D]] {
        let ranges = contiguousRanges()
        let step = Swift.max(1, count / Swift.max(1, budget))
        return ranges.compactMap { range -> [CLLocationCoordinate2D]? in
            guard range.count > 1 else { return nil }
            var piece = stride(from: range.lowerBound, to: range.upperBound, by: step)
                .filter { self[$0].hasValidPosition }
                .map { self[$0].clCoordinate }
            if self[range.upperBound].hasValidPosition {
                piece.append(self[range.upperBound].clCoordinate)
            }
            return piece.count > 1 ? piece : nil
        }
    }
}
