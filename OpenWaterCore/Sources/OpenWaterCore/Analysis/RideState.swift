import Foundation

/// What the rider was doing at a given moment.
///
/// This exists because of a specific, universal problem: a wingfoil track drawn
/// as one speed-coloured line is unreadable. An hour of reaching back and forth
/// in a bay produces forty overlapping passes through the same water, and no
/// amount of colour-ramping fixes it — you cannot tell a flight from a swim, a
/// gybe from a fall, or run three from run thirty.
///
/// Classifying every sample into a small number of *states* is what makes the
/// track parseable. Once each moment is labelled, the map can draw flying
/// segments boldly and swimming thinly, drop a marker at every fall, and let the
/// rider isolate a single run out of the tangle.
public enum RideState: String, Sendable, Codable, CaseIterable {

    /// Up on the foil.
    case foiling

    /// Moving properly but on the water — planing, displacement, or a
    /// non-foiling sport.
    case riding

    /// Moving slowly. Schlogging, drifting, paddling back.
    case slow

    /// Stopped, but not after a flight — waiting for wind, sorting gear.
    case stopped

    /// Stopped right after coming off the foil. This is a fall, and it is the
    /// state riders most want to see on the map.
    case fall

    public var displayName: String {
        switch self {
        case .foiling: "Flying"
        case .riding: "Riding"
        case .slow: "Slow"
        case .stopped: "Stopped"
        case .fall: "Fall"
        }
    }

    /// Whether this state should be drawn as a prominent line on the map.
    /// The rest is context and should recede.
    public var isPrimary: Bool { self == .foiling || self == .riding }

    /// Whether it should be marked with a pin rather than a line.
    public var isEvent: Bool { self == .fall }
}

/// A fall: off the foil and stopped, needing a restart.
///
/// Distinguished from a touchdown, which is a brief kiss of the water that the
/// rider rides straight out of. The difference matters enormously for
/// progression — "twelve touchdowns" is a normal session, "twelve falls" is a
/// hard one — so they are counted separately rather than lumped together.
public struct Fall: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    /// When the rider came off.
    public let elapsed: TimeInterval
    public let index: Int

    /// Where it happened, for the map marker.
    public let coordinate: Geo.Coordinate

    /// Speed at the moment before it went wrong.
    public let speedBefore: Double

    /// Seconds spent stopped before moving again. `nil` if the session ended here.
    public let recoveryTime: TimeInterval?

    /// Whether the rider got back onto the foil afterwards.
    public let gotBackUp: Bool

    /// 0–1. Falls detected without motion data are inferred from speed alone.
    public let confidence: Double

    public init(
        id: Int, elapsed: TimeInterval, index: Int, coordinate: Geo.Coordinate,
        speedBefore: Double, recoveryTime: TimeInterval?, gotBackUp: Bool, confidence: Double
    ) {
        self.id = id
        self.elapsed = elapsed
        self.index = index
        self.coordinate = coordinate
        self.speedBefore = speedBefore
        self.recoveryTime = recoveryTime
        self.gotBackUp = gotBackUp
        self.confidence = confidence
    }
}

/// Falls and the streaks between them.
public struct FallSummary: Hashable, Sendable, Codable {

    public let falls: [Fall]

    /// Total seconds spent in the water after a fall.
    public let timeLost: TimeInterval

    /// Mean seconds from falling to moving again — your water-start speed.
    public let averageRecoveryTime: TimeInterval?

    /// The longest stretch of riding with no fall, in time and distance.
    /// This is the number that tracks real progression in winging: not how fast
    /// you went, but how long you stayed up.
    public let longestCleanStreak: TimeInterval
    public let longestCleanDistance: Double

    /// Mean distance between falls.
    public let distancePerFall: Double?

    /// Falls per hour of moving time, which is comparable across sessions of
    /// different lengths.
    public let fallsPerHour: Double

    public var count: Int { falls.count }

    public init(
        falls: [Fall], timeLost: TimeInterval, averageRecoveryTime: TimeInterval?,
        longestCleanStreak: TimeInterval, longestCleanDistance: Double,
        distancePerFall: Double?, fallsPerHour: Double
    ) {
        self.falls = falls
        self.timeLost = timeLost
        self.averageRecoveryTime = averageRecoveryTime
        self.longestCleanStreak = longestCleanStreak
        self.longestCleanDistance = longestCleanDistance
        self.distancePerFall = distancePerFall
        self.fallsPerHour = fallsPerHour
    }

    public static let none = FallSummary(
        falls: [], timeLost: 0, averageRecoveryTime: nil,
        longestCleanStreak: 0, longestCleanDistance: 0,
        distancePerFall: nil, fallsPerHour: 0
    )
}

/// A contiguous stretch of one `RideState`, ready to draw.
public struct StateSegment: Hashable, Sendable, Codable, Identifiable {

    public let id: Int
    public let state: RideState
    public let startIndex: Int
    public let endIndex: Int
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let distance: Double
    public let averageSpeed: Double
    public let maxSpeed: Double

    /// Which run this segment belongs to, so the map can dim everything except
    /// the selected one.
    public var runIndex: Int?

    public var duration: TimeInterval { endElapsed - startElapsed }

    public init(
        id: Int, state: RideState, startIndex: Int, endIndex: Int,
        startElapsed: TimeInterval, endElapsed: TimeInterval,
        distance: Double, averageSpeed: Double, maxSpeed: Double, runIndex: Int? = nil
    ) {
        self.id = id
        self.state = state
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.maxSpeed = maxSpeed
        self.runIndex = runIndex
    }
}

/// Classifies every sample and produces drawable segments, falls, and streaks.
public struct RideStateClassifier: Sendable {

    public var thresholds: SportThresholds

    /// Below this the rider counts as stopped.
    public var stoppedSpeed: Double

    /// A stop must last at least this long after a flight to count as a fall
    /// rather than a momentary hesitation.
    public var minimumFallDuration: TimeInterval

    /// A stop within this long of a flight ending is attributed to that flight,
    /// i.e. it is a fall rather than an unrelated stop.
    public var fallAttributionWindow: TimeInterval

    public init(
        thresholds: SportThresholds = SportThresholds.forSport(.wingfoil),
        stoppedSpeed: Double = 1.5,
        minimumFallDuration: TimeInterval = 4,
        fallAttributionWindow: TimeInterval = 8
    ) {
        self.thresholds = thresholds
        self.stoppedSpeed = stoppedSpeed
        self.minimumFallDuration = minimumFallDuration
        self.fallAttributionWindow = fallAttributionWindow
    }

    public static func forSport(_ sport: Sport) -> RideStateClassifier {
        var c = RideStateClassifier(thresholds: sport.thresholds)
        c.stoppedSpeed = max(1.0, sport.thresholds.movingSpeed)
        switch sport {
        case .sup, .kayak:
            c.stoppedSpeed = 0.5
        case .sail:
            c.stoppedSpeed = 0.5
            c.minimumFallDuration = 30   // a keelboat does not fall over
        default:
            break
        }
        return c
    }

    // MARK: - Classify

    /// Per-sample state.
    public func classify(track: Track, flights: [Flight]) -> [RideState] {
        guard !track.isEmpty else { return [] }

        var flying = [Bool](repeating: false, count: track.count)
        for f in flights where f.startIndex >= 0 && f.endIndex < track.count {
            for i in f.startIndex...f.endIndex { flying[i] = true }
        }

        var states = [RideState](repeating: .stopped, count: track.count)
        for i in 0..<track.count {
            let speed = track.speed[i]
            if flying[i] {
                states[i] = .foiling
            } else if speed >= thresholds.movingSpeed * 2 {
                states[i] = .riding
            } else if speed >= stoppedSpeed {
                states[i] = .slow
            } else {
                states[i] = .stopped
            }
        }

        // Promote stops that follow a flight to falls.
        for f in flights {
            guard f.endIndex + 1 < track.count else { continue }
            let flightEnd = track.elapsed[f.endIndex]

            // Find the first stop within the attribution window.
            var i = f.endIndex + 1
            var stopStart: Int?
            while i < track.count, track.elapsed[i] - flightEnd <= fallAttributionWindow {
                if states[i] == .stopped { stopStart = i; break }
                i += 1
            }
            guard let start = stopStart else { continue }

            // How long does it last?
            var end = start
            while end + 1 < track.count, states[end + 1] == .stopped { end += 1 }
            guard track.elapsed[end] - track.elapsed[start] >= minimumFallDuration else { continue }

            for k in start...end { states[k] = .fall }
        }

        return states
    }

    // MARK: - Segments

    /// Collapse the per-sample states into drawable runs of the same state.
    ///
    /// Two details matter for the result to actually draw correctly:
    ///
    /// - **Consecutive segments share their boundary sample.** If segment A ends
    ///   at index 61 and segment B starts at 62, the polylines drawn from them
    ///   have a one-sample hole between them, and at 20 knots that is a visible
    ///   10 m gap in the track at every state change. Sharing the boundary costs
    ///   one sample of bleed in each segment's statistics and makes the drawn
    ///   line continuous.
    /// - **A state that lasts a single sample still produces a segment.** Losing
    ///   it would leave exactly the same hole.
    ///
    /// A minimum duration is enforced on top of that, so a single noisy sample
    /// does not shatter a long flight into three segments — which on a map reads
    /// as flicker rather than as information.
    public func segments(
        track: Track,
        states: [RideState],
        runs: [Run] = [],
        minimumDuration: TimeInterval = 1.5
    ) -> [StateSegment] {
        guard track.count == states.count, !states.isEmpty else { return [] }

        // Smooth out one-sample flickers first.
        var smoothed = states
        for i in 1..<(states.count - 1) where states[i - 1] == states[i + 1] && states[i] != states[i - 1] {
            smoothed[i] = states[i - 1]
        }

        var segments: [StateSegment] = []
        var start = 0

        func emit(from a: Int, to b: Int) {
            guard b > a else { return }
            let duration = track.elapsed[b] - track.elapsed[a]
            // Short segments are merged into the previous one rather than
            // dropped, so the timeline stays gap-free.
            if duration < minimumDuration, var last = segments.popLast() {
                last = StateSegment(
                    id: last.id,
                    state: last.state,
                    startIndex: last.startIndex,
                    endIndex: b,
                    startElapsed: last.startElapsed,
                    endElapsed: track.elapsed[b],
                    distance: track.cumulativeDistance[b] - track.cumulativeDistance[last.startIndex],
                    averageSpeed: track.meanSpeed(from: last.startIndex, to: b),
                    maxSpeed: max(last.maxSpeed, (last.startIndex...b).map { track.speed[$0] }.max() ?? 0),
                    runIndex: last.runIndex
                )
                segments.append(last)
                return
            }

            var maxSpeed = 0.0
            for i in a...b { maxSpeed = max(maxSpeed, track.speed[i]) }

            segments.append(StateSegment(
                id: segments.count,
                state: smoothed[a],
                startIndex: a,
                endIndex: b,
                startElapsed: track.elapsed[a],
                endElapsed: track.elapsed[b],
                distance: track.cumulativeDistance[b] - track.cumulativeDistance[a],
                averageSpeed: track.meanSpeed(from: a, to: b),
                maxSpeed: maxSpeed,
                runIndex: runs.first { $0.startIndex <= a && $0.endIndex >= b }?.index
            ))
        }

        // Each segment ends *on* the first sample of the next state, and the
        // next segment starts there too, so the drawn line is continuous.
        for i in 1..<smoothed.count where smoothed[i] != smoothed[start] {
            emit(from: start, to: i)
            start = i
        }
        emit(from: start, to: smoothed.count - 1)

        return segments
    }

    // MARK: - Falls

    public func falls(track: Track, states: [RideState], flights: [Flight]) -> FallSummary {
        guard track.count == states.count, !states.isEmpty else { return .none }

        var falls: [Fall] = []
        var timeLost: TimeInterval = 0
        let hasMotion = track.points.contains { $0.verticalAccelSD != nil }

        var i = 0
        while i < states.count {
            guard states[i] == .fall else { i += 1; continue }
            var end = i
            while end + 1 < states.count, states[end + 1] == .fall { end += 1 }

            let duration = track.elapsed[end] - track.elapsed[i]
            timeLost += duration

            // Did they get back on the foil afterwards?
            let gotBackUp = flights.contains { $0.startIndex > end }

            falls.append(Fall(
                id: falls.count,
                elapsed: track.elapsed[i],
                index: i,
                coordinate: track.points[i].coordinate,
                speedBefore: i > 0 ? track.speed[max(0, i - 3)] : track.speed[i],
                recoveryTime: end + 1 < states.count ? duration : nil,
                gotBackUp: gotBackUp,
                confidence: hasMotion ? 0.85 : 0.55
            ))
            i = end + 1
        }

        // Clean streaks: the gaps between falls, measured over riding time only.
        var longestTime: TimeInterval = 0
        var longestDistance = 0.0
        var streakStart = 0
        for fall in falls {
            let time = track.elapsed[fall.index] - track.elapsed[streakStart]
            let distance = track.cumulativeDistance[fall.index] - track.cumulativeDistance[streakStart]
            if time > longestTime { longestTime = time; longestDistance = distance }
            streakStart = fall.index
        }
        // The stretch after the last fall counts too.
        if streakStart < track.count - 1 {
            let time = track.duration - track.elapsed[streakStart]
            let distance = track.totalDistance - track.cumulativeDistance[streakStart]
            if time > longestTime { longestTime = time; longestDistance = distance }
        }

        let recoveries = falls.compactMap(\.recoveryTime)
        let movingTime = track.elapsed.isEmpty ? 0 : track.duration

        return FallSummary(
            falls: falls,
            timeLost: timeLost,
            averageRecoveryTime: recoveries.isEmpty
                ? nil
                : recoveries.reduce(0, +) / Double(recoveries.count),
            longestCleanStreak: longestTime,
            longestCleanDistance: longestDistance,
            distancePerFall: falls.isEmpty ? nil : track.totalDistance / Double(falls.count),
            fallsPerHour: movingTime > 0 ? Double(falls.count) / (movingTime / 3600) : 0
        )
    }
}
