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
    static func group(_ lanes: [SessionRibbon.Lane], absorb: Double = 60) -> [GroupedRun] {
        var groups: [[SessionRibbon.Lane]] = []
        var kinds: [Kind] = []

        for lane in lanes.sorted(by: { $0.startElapsed < $1.startElapsed }) {
            let kind = Kind(lane.pointOfSail)
            if let current = kinds.last,
               kind == current || lane.distance < absorb {
                groups[groups.count - 1].append(lane)
            } else {
                groups.append([lane])
                kinds.append(kind)
            }
        }

        // The loop above can only absorb a short stretch into a run already
        // under way, which leaves the very first one unreachable: a session
        // that opens with a few seconds of getting going would report that as
        // a run of its own before the real first run. Merge it forward.
        //
        // Only the first group can be this short. Every later group begins
        // with a stretch that cleared `absorb` — that is what started it.
        if groups.count > 1, groups[0].reduce(0, { $0 + $1.distance }) < absorb {
            groups[1].insert(contentsOf: groups[0], at: 0)
            groups.removeFirst()
            kinds.removeFirst()
        }

        // A group's kind is decided by the distance sailed on each point of
        // sail inside it, not by whichever stretch happened to come first.
        var runs: [GroupedRun] = []
        var seen: [Kind: Int] = [:]
        for (index, group) in groups.enumerated() {
            var byKind: [Kind: Double] = [:]
            for lane in group { byKind[Kind(lane.pointOfSail), default: 0] += lane.distance }
            let kind = byKind.max { $0.value < $1.value }?.key ?? .reaching
            seen[kind, default: 0] += 1
            runs.append(GroupedRun(id: index, kind: kind, number: seen[kind]!, lanes: group))
        }
        return runs
    }
}
