import OpenWaterCore
import SwiftUI

/// A run, as a rider counts them.
///
/// The segmenter splits on every meaningful change of direction, which on a
/// lapping day is sixty-seven pieces: each weave down the river and each tack
/// back up. A rider looking at that same session says "six downwinders and
/// five beats back". Both are descriptions of the same track; only one is an
/// answer to a question anybody asks.
///
/// So consecutive stretches sailed on the same point of sail merge into one
/// run. The stretches survive inside it — an upwind run's tacks are worth
/// counting — but the run is the unit the screens are built on, and the same
/// grouping feeds the Runs tab and the Downwind screen so the two can never
/// disagree about how many there were.
struct GroupedRun: Identifiable {

    enum Kind: String, CaseIterable {
        case downwind, reaching, upwind

        var title: String {
            switch self {
            case .downwind: "Downwind"
            case .reaching: "Reaching"
            case .upwind: "Upwind"
            }
        }

        /// One colour per kind, shared by every map that draws runs.
        ///
        /// The Runs map and the Downwind screen have to agree: a rider who
        /// sees an orange run on one and a blue one on the other, for the
        /// same stretch of water, learns to distrust both. Downwind keeps the
        /// app's accent because that screen was drawing it that way first.
        /// Named literally rather than `.accentColor`. Inside `MapPolyline`
        /// the accent does not resolve reliably — the same line drew orange
        /// unselected and system blue selected — which is the sibling of the
        /// `.tint` problem already found on the Downwind map.
        var colour: Color {
            switch self {
            case .downwind: Color(red: 0.94, green: 0.35, blue: 0.20)
            case .reaching: .teal
            case .upwind: .indigo
            }
        }

        /// What a single run of this kind is called.
        var runName: String {
            switch self {
            case .downwind: "Downwind run"
            case .reaching: "Reach"
            case .upwind: "Upwind run"
            }
        }

        /// What the pieces inside it are.
        ///
        /// Only upwind has pieces worth naming: each tack is a deliberate
        /// change of side. A downwinder's stretches are weaves across the
        /// bumps, which nobody counts.
        var pieceName: String? {
            self == .upwind ? "tacks" : nil
        }

        init(_ point: PointOfSail?) {
            switch point {
            case .noGo, .closeHauled: self = .upwind
            case .broadReach, .running: self = .downwind
            default: self = .reaching
            }
        }
    }

    let id: Int
    let kind: Kind
    /// Position within its own kind — "Downwind run 3".
    var number: Int
    let lanes: [SessionRibbon.Lane]

    /// Seconds off the foil between the previous run and this one.
    ///
    /// The other half of `isLinked`: linked says the join was clean, this
    /// says how long the swim was when it was not. A rider reading a session
    /// back wants both — five seconds is a touch-and-go, fifty is walking the
    /// board back upwind, and a list that shows neither makes them look the
    /// same.
    ///
    /// Nil on the first run, on a linked one, and whenever flight detection
    /// cannot say.
    var offFoilBefore: TimeInterval?

    /// Whether the rider got here from the previous run without touching down.
    ///
    /// Linking runs is the thing riders actually chase: turning without
    /// dropping off the foil is harder than the run either side of it, and a
    /// session of six linked runs is a different afternoon from six runs with
    /// a swim between each. Always false on a session with no flight
    /// detection — nothing is known about touchdowns there, and silence is
    /// better than a guess.
    var isLinked: Bool = false

    var distance: Double { lanes.reduce(0) { $0 + $1.distance } }
    var duration: TimeInterval {
        guard let first = lanes.first, let last = lanes.last else { return 0 }
        return last.endElapsed - first.startElapsed
    }
    var averageSpeed: Double { duration > 0 ? distance / duration : 0 }
    var maxSpeed: Double { lanes.map(\.maxSpeed).max() ?? 0 }
    var foilingFraction: Double {
        guard distance > 0 else { return 0 }
        return lanes.reduce(0) { $0 + $1.foilingFraction * $1.distance } / distance
    }

    /// Degrees off dead downwind, averaged over the run's own stretches.
    var alignment: Double? {
        let angles = lanes.compactMap(\.trueWindAngle).map { abs(180 - abs($0)) }
        guard !angles.isEmpty else { return nil }
        return angles.reduce(0, +) / Double(angles.count)
    }

    var startElapsed: TimeInterval { lanes.first?.startElapsed ?? 0 }
    var endElapsed: TimeInterval { lanes.last?.endElapsed ?? 0 }

    /// Runs of this session, in time order.
    ///
    /// A stretch shorter than `absorb` never starts a new run — the brief
    /// reach while bearing away from a beat is part of the turn, not a leg of
    /// its own, and letting it split the run is how six downwinders became
    /// thirty-four.
    ///
    /// **A run never spans a touchdown.** Coming off the foil ends the ride,
    /// whatever the rider was pointing at either side of it, and a screen that
    /// merges across one reports thirty-six minutes and seven and a half
    /// kilometres as a single reach when the rider swam six times inside it.
    /// Pass `flights` to get that split; without them this groups on point of
    /// sail alone, which is what a non-foiling sport wants.
    /// - Parameter reversal: degrees of heading change that end a run.
    ///   A reach out and a reach back are two runs to the rider and one point
    ///   of sail to the segmenter, which is why a session with forty-eight
    ///   turns could report eleven runs. Weaving down a downwinder is not the
    ///   same event: those headings sit maybe forty degrees either side of
    ///   dead downwind, where a genuine reversal is nearer a hundred and
    ///   eighty. The default leaves room on both sides of that gap.
    static func group(
        _ lanes: [SessionRibbon.Lane],
        flights: [Flight] = [],
        absorb: Double = 60,
        touchdown: Double = 3,
        reversal: Double = 120
    ) -> [GroupedRun] {
        let flown = rides(from: flights, touchdown: touchdown)

        var groups: [[SessionRibbon.Lane]] = []
        var kinds: [Kind] = []
        var rides: [Int?] = []

        // The heading each open run is established on, as a distance-weighted
        // circular mean. Short absorbed stretches are deliberately kept out of
        // it: those are the turn itself, and letting a mid-gybe heading drag
        // the mean around would blunt the very comparison it exists for.
        var bearings: [(x: Double, y: Double)] = []

        for lane in lanes.sorted(by: { $0.startElapsed < $1.startElapsed }) {
            let kind = Kind(lane.pointOfSail)
            let ride = ride(of: lane, in: flown)
            let brief = lane.distance < absorb
            let reversed = bearings.last.map {
                separation(between: atan2($0.x, $0.y) * 180 / .pi, and: lane.heading) > reversal
            } ?? false

            if let current = kinds.last, ride == rides[rides.count - 1],
               !(reversed && !brief),
               kind == current || brief {
                groups[groups.count - 1].append(lane)
                if !brief {
                    let radians = lane.heading * .pi / 180
                    bearings[bearings.count - 1].x += sin(radians) * lane.distance
                    bearings[bearings.count - 1].y += cos(radians) * lane.distance
                }
            } else {
                groups.append([lane])
                kinds.append(kind)
                rides.append(ride)
                let radians = lane.heading * .pi / 180
                bearings.append((sin(radians) * lane.distance, cos(radians) * lane.distance))
            }
        }

        // The loop above can only absorb a short stretch into a run already
        // under way, which leaves the very first one unreachable: a session
        // that opens with a few seconds of getting going would report that as
        // a run of its own before the real first run. Merge it forward.
        //
        // Only the first group can be this short. Every later group begins
        // with a stretch that cleared `absorb` — that is what started it.
        //
        // It merges forward only within the same ride: a first stretch that
        // ends in a swim is short *because* of the swim, and folding it into
        // the next flight would span the touchdown this method exists to
        // respect.
        if groups.count > 1, rides[0] == rides[1],
           groups[0].reduce(0, { $0 + $1.distance }) < absorb {
            groups[1].insert(contentsOf: groups[0], at: 0)
            groups.removeFirst()
            kinds.removeFirst()
            rides.removeFirst()
        }

        // A run is a ride.
        //
        // Splitting at touchdowns leaves the stretches between them standing
        // on their own, and those are the swim back out and the drift between
        // attempts — real distance, but not something a rider counts. Left in,
        // they bury the rides: sixteen reaching runs where two of them are
        // 134 m at three knots. They belong to the session, not to this list.
        //
        // The ride each surviving group belongs to is carried alongside it,
        // not discarded with the filter: two runs in the same ride are two
        // runs the rider linked without touching down, and that is the whole
        // difference between a good session and a tiring one.
        var kept = Array(zip(groups, rides))
        if !flown.isEmpty {
            kept = kept.filter { $0.1 != nil }
        }

        // A group's kind is decided by the distance sailed on each point of
        // sail inside it, not by whichever stretch happened to come first.
        var runs: [GroupedRun] = []
        var seen: [Kind: Int] = [:]
        for (index, entry) in kept.enumerated() {
            let (group, ride) = entry
            var byKind: [Kind: Double] = [:]
            for lane in group { byKind[Kind(lane.pointOfSail), default: 0] += lane.distance }
            let kind = byKind.max { $0.value < $1.value }?.key ?? .reaching
            seen[kind, default: 0] += 1

            // Linked when the previous run ended in the same flight this one
            // begins in. `ride != nil` matters: without flight detection every
            // run has a nil ride, and nil == nil would call the whole session
            // linked while claiming to know something it does not.
            let linked = index > 0 && ride != nil && kept[index - 1].1 == ride

            // How long the rider was down for, when they were down: the gap
            // between the ride that ended and the one that starts here.
            var offFoil: TimeInterval?
            if index > 0, !linked,
               let ride, let previous = kept[index - 1].1,
               ride < flown.count, previous < flown.count {
                let gap = flown[ride].start - flown[previous].end
                if gap > 0 { offFoil = gap }
            }

            runs.append(GroupedRun(id: index, kind: kind, number: seen[kind]!,
                                   lanes: group, offFoilBefore: offFoil,
                                   isLinked: linked))
        }
        return runs
    }

    /// Degrees between two bearings, the short way round.
    private static func separation(between a: Double, and b: Double) -> Double {
        let raw = abs((a - b).truncatingRemainder(dividingBy: 360))
        return raw > 180 ? 360 - raw : raw
    }

    /// Flights joined across momentary touchdowns.
    ///
    /// The foil detector ends a flight the instant the board touches, which is
    /// the right answer to "how long were you flying" and the wrong one to
    /// "how many runs did you do" — a tap and a swim are not the same event.
    /// Flights less than `touchdown` apart are one ride.
    private static func rides(
        from flights: [Flight], touchdown: Double
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var rides: [(start: TimeInterval, end: TimeInterval)] = []
        for flight in flights.sorted(by: { $0.startElapsed < $1.startElapsed }) {
            if let last = rides.last, flight.startElapsed - last.end < touchdown {
                rides[rides.count - 1].end = max(last.end, flight.endElapsed)
            } else {
                rides.append((flight.startElapsed, flight.endElapsed))
            }
        }
        return rides
    }

    /// Which ride a stretch belongs to, or nil if it was sailed on the water.
    ///
    /// By greatest overlap rather than by containment: a stretch that begins
    /// off the foil and ends flying belongs to the flight, and one that spans
    /// a touchdown belongs to whichever side of it lasted longer. That is as
    /// fine as this can get — a run is built from whole stretches, so a
    /// touchdown in the middle of one cannot split it.
    private static func ride(
        of lane: SessionRibbon.Lane, in rides: [(start: TimeInterval, end: TimeInterval)]
    ) -> Int? {
        var best: (index: Int, overlap: TimeInterval)?
        for (index, ride) in rides.enumerated() {
            let overlap = min(lane.endElapsed, ride.end) - max(lane.startElapsed, ride.start)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (index, overlap) }
        }
        return best?.index
    }
}
