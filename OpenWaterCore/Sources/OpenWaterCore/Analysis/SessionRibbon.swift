import Foundation

/// A session laid out as parallel lanes instead of as a map.
///
/// The map is the wrong projection for a wing session. Forty reaches through the
/// same half-kilometre of bay overlap into a scribble where nothing is legible —
/// you cannot see which pass was your fastest, when you were flying, or where the
/// falls were. That is not a rendering problem to be solved with better colours;
/// the information is genuinely occluded, because geography puts run 3 on top of
/// run 30.
///
/// The fix is to stop plotting geography. Each run becomes its own horizontal
/// lane, stacked in time order. Nothing overlaps, because time never overlaps.
/// Within a lane, position is distance along the run, colour is speed, and fill
/// is ride state — so a session reads top to bottom like a score: forty lanes,
/// and you can see at a glance which ones were clean flights and which ones
/// ended in the water.
///
/// The map stays, for *where*. This answers *what happened*.
public struct SessionRibbon: Hashable, Sendable, Codable {

    public let lanes: [Lane]

    /// Events that sit between lanes — the maneuvers and falls that link one run
    /// to the next.
    public let connectors: [Connector]

    /// Longest lane distance, so a view can scale all lanes to a common axis and
    /// make run lengths visually comparable.
    public let maxLaneDistance: Double
    public let maxLaneDuration: TimeInterval

    /// Fastest speed anywhere, for a shared colour scale across lanes.
    public let maxSpeed: Double

    public var isEmpty: Bool { lanes.isEmpty }

    public init(
        lanes: [Lane], connectors: [Connector],
        maxLaneDistance: Double, maxLaneDuration: TimeInterval, maxSpeed: Double
    ) {
        self.lanes = lanes
        self.connectors = connectors
        self.maxLaneDistance = maxLaneDistance
        self.maxLaneDuration = maxLaneDuration
        self.maxSpeed = maxSpeed
    }

    /// One run, as a row.
    public struct Lane: Hashable, Sendable, Codable, Identifiable {

        public let id: Int

        /// The run this lane represents.
        public let runIndex: Int

        public let startElapsed: TimeInterval
        public let endElapsed: TimeInterval
        public let distance: Double
        public let averageSpeed: Double
        public let maxSpeed: Double

        /// Heading of the run, so lanes can be labelled and grouped by direction
        /// — which is how you spot that all your slow runs were on one tack.
        public let heading: Double
        public let tack: Tack?
        public let pointOfSail: PointOfSail?
        public let trueWindAngle: Double?

        /// Fraction of the lane spent flying.
        public let foilingFraction: Double

        /// The cells that make up the lane, in order.
        public let cells: [Cell]

        public var duration: TimeInterval { endElapsed - startElapsed }
    }

    /// A slice of a lane: one stretch of constant state, with its speed.
    ///
    /// Cells are the drawable unit. They carry normalised positions so a view can
    /// render a lane without knowing anything about tracks or geodesy.
    public struct Cell: Hashable, Sendable, Codable {

        public let state: RideState

        /// Where the cell starts and ends along the lane, 0–1 of the lane's
        /// distance. Distance rather than time, so a slow patch takes up the
        /// space it actually occupies on the water rather than being stretched.
        public let start: Double
        public let end: Double

        public let averageSpeed: Double
        public let maxSpeed: Double
        public let duration: TimeInterval

        /// Index range back into the track, so tapping a cell can select the
        /// matching stretch on the map.
        public let startIndex: Int
        public let endIndex: Int

        public var width: Double { max(0, end - start) }
    }

    /// What happened between two lanes.
    public struct Connector: Hashable, Sendable, Codable, Identifiable {

        public enum Kind: String, Sendable, Codable {
            case gybe, tack, carve, turn
            /// Came off the foil in the transition and had to get going again,
            /// but did not stop dead.
            case drop
            case fall
            case gap

            public var displayName: String {
                switch self {
                case .gybe: "Gybe"
                case .tack: "Tack"
                case .carve: "Carve"
                case .turn: "Turn"
                case .drop: "Dropped"
                case .fall: "Fall"
                case .gap: "Break"
                }
            }
        }

        public let id: Int
        public let kind: Kind

        /// Lanes either side. `nil` at the start or end of the session.
        public let fromLane: Int?
        public let toLane: Int?

        public let elapsed: TimeInterval
        public let duration: TimeInterval

        /// Maneuver score, 0–100, when this connector is a maneuver.
        public let score: Double?

        /// Whether the rider stayed on the foil through it.
        public let stayedOnFoil: Bool?
    }
}

/// Builds a `SessionRibbon` from an analysed session.
public struct SessionRibbonBuilder: Sendable {

    /// Lanes shorter than this are folded away — a two-second twitch between two
    /// real runs is noise, and giving it a lane of its own defeats the purpose.
    public var minimumLaneDistance: Double

    public init(minimumLaneDistance: Double = 50) {
        self.minimumLaneDistance = minimumLaneDistance
    }

    public func build(
        track: Track,
        runs: [Run],
        segments: [StateSegment],
        maneuvers: [Maneuver],
        falls: [Fall],
        states: [RideState] = []
    ) -> SessionRibbon {
        let usableRuns = runs.filter { $0.distance >= minimumLaneDistance }
        guard !usableRuns.isEmpty else {
            return SessionRibbon(
                lanes: [], connectors: [],
                maxLaneDistance: 0, maxLaneDuration: 0, maxSpeed: 0
            )
        }

        var lanes: [SessionRibbon.Lane] = []

        for (position, run) in usableRuns.enumerated() {
            let runStartDistance = track.cumulativeDistance[run.startIndex]
            let runDistance = max(1e-6, run.distance)

            // Segments overlapping this run, clipped to it.
            var cells: [SessionRibbon.Cell] = []
            var foilingDistance = 0.0

            for segment in segments {
                let a = max(segment.startIndex, run.startIndex)
                let b = min(segment.endIndex, run.endIndex)
                guard b > a else { continue }

                let startOffset = (track.cumulativeDistance[a] - runStartDistance) / runDistance
                let endOffset = (track.cumulativeDistance[b] - runStartDistance) / runDistance
                guard endOffset > startOffset else { continue }

                var maxSpeed = 0.0
                for i in a...b { maxSpeed = max(maxSpeed, track.speed[i]) }

                if segment.state == .foiling {
                    foilingDistance += track.cumulativeDistance[b] - track.cumulativeDistance[a]
                }

                cells.append(SessionRibbon.Cell(
                    state: segment.state,
                    start: min(1, max(0, startOffset)),
                    end: min(1, max(0, endOffset)),
                    averageSpeed: track.meanSpeed(from: a, to: b),
                    maxSpeed: maxSpeed,
                    duration: track.elapsed[b] - track.elapsed[a],
                    startIndex: a,
                    endIndex: b
                ))
            }

            lanes.append(SessionRibbon.Lane(
                id: position,
                runIndex: run.index,
                startElapsed: run.startElapsed,
                endElapsed: run.endElapsed,
                distance: run.distance,
                averageSpeed: run.averageSpeed,
                maxSpeed: run.maxSpeed,
                heading: run.meanHeading,
                tack: run.tack,
                pointOfSail: run.point,
                trueWindAngle: run.trueWindAngle,
                foilingFraction: run.distance > 0 ? foilingDistance / run.distance : 0,
                cells: cells.sorted { $0.start < $1.start }
            ))
        }

        let connectors = buildConnectors(
            lanes: lanes, maneuvers: maneuvers, falls: falls, track: track, states: states
        )

        return SessionRibbon(
            lanes: lanes,
            connectors: connectors,
            maxLaneDistance: lanes.map(\.distance).max() ?? 0,
            maxLaneDuration: lanes.map(\.duration).max() ?? 0,
            maxSpeed: lanes.map(\.maxSpeed).max() ?? 0
        )
    }

    /// Work out what joins each pair of consecutive lanes.
    ///
    /// A maneuver in the gap means the rider turned; a fall in the gap means they
    /// did not. When both are present the fall wins, because "you fell" is the
    /// more important fact about that transition.
    private func buildConnectors(
        lanes: [SessionRibbon.Lane],
        maneuvers: [Maneuver],
        falls: [Fall],
        track: Track,
        states: [RideState]
    ) -> [SessionRibbon.Connector] {
        guard lanes.count > 1 else { return [] }
        var connectors: [SessionRibbon.Connector] = []

        for i in 0..<(lanes.count - 1) {
            let gapStart = lanes[i].endElapsed
            let gapEnd = lanes[i + 1].startElapsed
            guard gapEnd >= gapStart else { continue }

            let fall = falls.first { $0.elapsed >= gapStart - 2 && $0.elapsed <= gapEnd + 2 }

            // Match by *overlap*, not containment. A gybe starts while the rider
            // is still on the old run and finishes after they are established on
            // the new one, so the maneuver routinely extends past the gap at both
            // ends — requiring containment matches almost nothing and leaves every
            // connector labelled as a generic turn.
            let maneuver = maneuvers
                .filter { $0.startElapsed <= gapEnd + 4 && $0.endElapsed >= gapStart - 4 }
                // When several overlap, take the one that covers the gap best.
                .max { a, b in
                    overlap(a, gapStart, gapEnd) < overlap(b, gapStart, gapEnd)
                }

            // What the rider was doing during the gap, which is what decides
            // between "you turned" and "you came off".
            let gapStates: [RideState] = states.isEmpty ? [] : {
                guard let a = track.index(atElapsed: gapStart),
                      let b = track.index(atElapsed: gapEnd),
                      b >= a, b < states.count else { return [] }
                return Array(states[a...b])
            }()
            let droppedOff = gapStates.contains { $0 == .slow || $0 == .stopped }

            let kind: SessionRibbon.Connector.Kind
            if fall != nil {
                kind = .fall
            } else if let maneuver {
                switch maneuver.kind {
                case .gybe: kind = .gybe
                case .tack: kind = .tack
                case .carve: kind = .carve
                case .turn: kind = .turn
                }
            } else if gapEnd - gapStart > 20 {
                kind = .gap
            } else if droppedOff {
                // No maneuver was detected because the rider had already slowed
                // below the threshold before turning. Calling that a "turn"
                // hides the interesting part: they dropped off the foil and had
                // to get going again.
                kind = .drop
            } else {
                kind = .turn
            }

            connectors.append(SessionRibbon.Connector(
                id: connectors.count,
                kind: kind,
                fromLane: lanes[i].id,
                toLane: lanes[i + 1].id,
                elapsed: gapStart,
                duration: gapEnd - gapStart,
                score: maneuver?.score,
                stayedOnFoil: maneuver?.stayedOnFoil
            ))
        }

        return connectors
    }

    /// Seconds of a maneuver that fall inside a gap between lanes.
    private func overlap(_ maneuver: Maneuver, _ start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        max(0, min(maneuver.endElapsed, end) - max(maneuver.startElapsed, start))
    }
}
