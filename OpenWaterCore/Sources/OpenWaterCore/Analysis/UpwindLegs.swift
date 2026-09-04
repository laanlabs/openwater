import Foundation

/// One board-on-the-wind stretch of working to windward.
///
/// A leg is what a rider means when they say "that port tack out to the
/// channel": continuous sailing on one tack, above a beam reach, long enough
/// to mean something. Legs are the unit the upwind story is told in — the
/// polar answers "what angle can you hold", the beat answers "what was the
/// best kilometre worth", and the legs answer "show me".
public struct UpwindLeg: Hashable, Sendable, Identifiable {

    public let index: Int
    public let startIndex: Int
    public let endIndex: Int
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let tack: Tack

    /// Distance-weighted mean angle off the wind, degrees — the working angle
    /// the leg was actually sailed at.
    public let meanAngle: Double

    /// Metres sailed through the water along the leg.
    public let distance: Double

    /// Metres made good to windward, net. Wandering costs it; a header the
    /// rider did not play costs it; this is the honest number.
    public let madeGood: Double

    public let averageSpeed: Double

    /// Made good over time — the leg's true upwind VMG.
    public var vmg: Double {
        let dt = endElapsed - startElapsed
        return dt > 0 ? madeGood / dt : 0
    }

    public var duration: TimeInterval { endElapsed - startElapsed }
    public var midIndex: Int { (startIndex + endIndex) / 2 }
    public var id: Int { index }

    public init(
        index: Int, startIndex: Int, endIndex: Int,
        startElapsed: TimeInterval, endElapsed: TimeInterval,
        tack: Tack, meanAngle: Double, distance: Double,
        madeGood: Double, averageSpeed: Double
    ) {
        self.index = index
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.tack = tack
        self.meanAngle = meanAngle
        self.distance = distance
        self.madeGood = madeGood
        self.averageSpeed = averageSpeed
    }
}

public enum UpwindLegFinder {

    /// Where upwind stops and reaching begins, in degrees off the wind.
    ///
    /// Public and shared, because two screens using two numbers for one word
    /// is how they came to disagree in front of a rider. The Upwind screen
    /// found twenty-four legs on a session where the Runs tab found thirteen
    /// upwind runs, and the whole of the difference was legs sailed at 69° to
    /// 78°: beating by this measure, reaching by the run list's own eighty.
    ///
    /// Ninety is the honest line — above a beam reach is upwind — and the run
    /// list reads it from here rather than keeping its own.
    public static let upwindLimit: Double = 90

    /// And where reaching stops and downwind begins. `PointOfSail` has always
    /// put it here and nothing about that one was wrong.
    public static let downwindLimit: Double = 120

    /// The upwind legs of a track, in sailed order.
    ///
    /// A sample belongs to a leg when the rider is moving and pointed above a
    /// beam reach; the leg breaks when the tack changes, the angle falls off
    /// the wind, or the boat stops for more than a few seconds. Short scraps
    /// are dropped — a two-second luff through head-to-wind is part of a tack,
    /// not a leg — but the floor is set by what a *short real tack* looks
    /// like, not a comfortable one: a tight beat swaps tacks every fifteen
    /// seconds, and stricter minimums (150 m, 25 s at first) silently
    /// swallowed half of a real session's zig-zag. Jitter stays out on the
    /// moving-speed floor, not on leg length.
    ///
    /// `madeGoodToward` is the axis a leg's `madeGood` and `vmg` are measured
    /// along — the rider's course when they named one, otherwise the wind.
    /// Which samples *are* a leg, and which tack, stay measured to the wind:
    /// a course changes what counts as progress, not what counts as upwind.
    public static func legs(
        track: Track,
        wind: Wind,
        madeGoodToward course: Double? = nil,
        upwindLimit: Double = UpwindLegFinder.upwindLimit,
        minimumSpeed: Double = 2.0,
        minimumDistance: Double = 80,
        minimumDuration: TimeInterval = 12,
        maximumStop: TimeInterval = 8
    ) -> [UpwindLeg] {
        let n = track.count
        guard n > 2 else { return [] }
        let metresPerDegree = 111_320.0
        // Unit vector pointing *at* the axis — the direction made good is
        // measured along. By default that is `directionFrom`: where the wind
        // comes from is exactly where upwind progress goes to.
        let axis = wind.madeGoodAxis(course: course) * .pi / 180
        let axisEast = sin(axis)
        let axisNorth = cos(axis)

        struct Building {
            var start: Int
            var lastActive: Int
            var tackIsPort: Bool
            var distance = 0.0
            var madeGood = 0.0
            var angleWeighted = 0.0
        }

        var legs: [UpwindLeg] = []
        var current: Building?

        func finish(_ leg: Building) {
            let start = leg.start, end = leg.lastActive
            guard end > start else { return }
            let dt = track.elapsed[end] - track.elapsed[start]
            guard leg.distance >= minimumDistance, dt >= minimumDuration else { return }
            legs.append(UpwindLeg(
                index: legs.count,
                startIndex: start, endIndex: end,
                startElapsed: track.elapsed[start], endElapsed: track.elapsed[end],
                tack: leg.tackIsPort ? .port : .starboard,
                meanAngle: leg.distance > 0 ? leg.angleWeighted / leg.distance : 0,
                distance: leg.distance,
                madeGood: max(0, leg.madeGood),
                averageSpeed: dt > 0 ? leg.distance / dt : 0
            ))
        }

        for i in 1..<n {
            let step = track.cumulativeDistance[i] - track.cumulativeDistance[i - 1]
            let speed = track.speed[i]
            let twa = wind.trueWindAngle(heading: track.course[i])
            let isUpwind = abs(twa) < upwindLimit && speed >= minimumSpeed
            let isPort = twa >= 0

            if var leg = current {
                let stopped = track.elapsed[i] - track.elapsed[leg.lastActive]
                if isUpwind, isPort == leg.tackIsPort {
                    let a = track.points[i - 1], b = track.points[i]
                    let dE = (b.longitude - a.longitude) * metresPerDegree * cos(a.latitude * .pi / 180)
                    let dN = (b.latitude - a.latitude) * metresPerDegree
                    leg.distance += step
                    leg.madeGood += dE * axisEast + dN * axisNorth
                    leg.angleWeighted += abs(twa) * step
                    leg.lastActive = i
                    current = leg
                } else if !isUpwind, stopped <= maximumStop {
                    // A brief luff, lull or bad fix inside the leg. Not
                    // accumulated, not fatal — a leg survives its rider
                    // pinching too high for a moment.
                    current = leg
                } else {
                    finish(leg)
                    current = nil
                }
            }

            if current == nil, isUpwind {
                current = Building(start: i - 1, lastActive: i, tackIsPort: isPort)
            }
        }
        if let leg = current { finish(leg) }
        return legs
    }
}
