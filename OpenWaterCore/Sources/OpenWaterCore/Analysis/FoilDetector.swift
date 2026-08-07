import Foundation

/// A continuous period out of the water.
public struct Flight: Hashable, Sendable, Codable, Identifiable {

    public let id: Int

    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    public let distance: Double
    public let averageSpeed: Double
    public let maxSpeed: Double

    /// Speed at the moment the board left the water — your takeoff speed, which
    /// is the number that tells you whether your foil is big enough.
    public let takeoffSpeed: Double

    /// Speed when it came back down.
    public let landingSpeed: Double

    /// 0–1. Low when the call rests on speed alone with no motion data.
    public let confidence: Double

    public var duration: TimeInterval { endElapsed - startElapsed }

    public init(
        id: Int, startElapsed: TimeInterval, endElapsed: TimeInterval,
        startIndex: Int, endIndex: Int,
        distance: Double, averageSpeed: Double, maxSpeed: Double,
        takeoffSpeed: Double, landingSpeed: Double, confidence: Double
    ) {
        self.id = id
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.distance = distance
        self.averageSpeed = averageSpeed
        self.maxSpeed = maxSpeed
        self.takeoffSpeed = takeoffSpeed
        self.landingSpeed = landingSpeed
        self.confidence = confidence
    }
}

/// Session-level flight statistics.
public struct FoilSummary: Hashable, Sendable, Codable {

    public let flightCount: Int

    /// Total seconds on foil.
    public let timeOnFoil: TimeInterval

    /// As a fraction of moving time, 0–1. The headline number.
    public let foilingFraction: Double

    public let distanceOnFoil: Double

    public let longestFlight: Flight?
    public let fastestFlight: Flight?

    /// Mean speed while flying — always higher than session average, and the
    /// more meaningful figure for a foiler.
    public let averageFlightSpeed: Double

    /// Mean speed at which the board left the water.
    public let averageTakeoffSpeed: Double

    /// Number of times the board touched back down mid-run.
    public let touchdownCount: Int

    /// Seconds from the start of riding to the first sustained flight — how
    /// long your pump-up takes, and a genuinely useful progression metric.
    public let timeToFirstFlight: TimeInterval?

    /// Whether motion data was available; without it these are speed-only
    /// inferences and should be presented as such.
    public let usedMotionData: Bool

    public init(
        flightCount: Int, timeOnFoil: TimeInterval, foilingFraction: Double,
        distanceOnFoil: Double, longestFlight: Flight?, fastestFlight: Flight?,
        averageFlightSpeed: Double, averageTakeoffSpeed: Double,
        touchdownCount: Int, timeToFirstFlight: TimeInterval?, usedMotionData: Bool
    ) {
        self.flightCount = flightCount
        self.timeOnFoil = timeOnFoil
        self.foilingFraction = foilingFraction
        self.distanceOnFoil = distanceOnFoil
        self.longestFlight = longestFlight
        self.fastestFlight = fastestFlight
        self.averageFlightSpeed = averageFlightSpeed
        self.averageTakeoffSpeed = averageTakeoffSpeed
        self.touchdownCount = touchdownCount
        self.timeToFirstFlight = timeToFirstFlight
        self.usedMotionData = usedMotionData
    }

    public static let none = FoilSummary(
        flightCount: 0, timeOnFoil: 0, foilingFraction: 0, distanceOnFoil: 0,
        longestFlight: nil, fastestFlight: nil, averageFlightSpeed: 0,
        averageTakeoffSpeed: 0, touchdownCount: 0, timeToFirstFlight: nil,
        usedMotionData: false
    )
}

/// Detects when the board is flying.
///
/// Two independent signals, because neither alone is good enough:
///
/// - **Speed.** A foil needs a minimum speed to generate lift, so anything below
///   takeoff speed is definitely not flying. But plenty of *displacement* riding
///   happens above that speed too, so speed alone over-reports badly.
/// - **Vertical acceleration.** This is the real tell. A board on the water
///   slams through every piece of chop; a board in the air does not. The
///   standard deviation of vertical acceleration collapses by roughly an order
///   of magnitude the moment you come up. When the watch recorded motion data,
///   this dominates the decision.
///
/// A hysteresis band and a minimum duration stop the state flickering, which
/// otherwise produces nonsense like 200 "flights" in a session.
public struct FoilDetector: Sendable {

    public var thresholds: SportThresholds

    /// Speed must exceed takeoff × this to start a flight, and fall below
    /// takeoff × `exitFactor` to end one. The gap is the hysteresis.
    public var entryFactor: Double
    public var exitFactor: Double

    /// Flights shorter than this are discarded.
    public var minimumDuration: TimeInterval

    /// Touchdowns shorter than this do not break a flight in two — clipping a
    /// wingtip is not a landing.
    public var minimumTouchdown: TimeInterval

    /// A dip may last up to this long and still not be a landing, provided it
    /// stayed shallow.
    ///
    /// Depth is what tells the two apart. A foil that really comes down loses
    /// speed hard, because the board is suddenly a boat — from flying speed it
    /// is at walking pace within a couple of seconds and takes far longer than
    /// this to get back up. A dip that bottoms out just under the flying
    /// threshold and recovers within a few seconds is a lull in the wind, and
    /// the rider never got wet.
    ///
    /// Found in a reported session: a rider who was up for the whole of a long
    /// downwind run had it broken into six flights by dips of three to five
    /// seconds that never fell below 7.6 knots. Treating those as landings cut
    /// a twenty-two minute flight into pieces and, downstream, cut the glide
    /// that ran alongside it into pieces too.
    public var shallowTouchdownWindow: TimeInterval

    /// How far below takeoff speed a dip may go and still count as shallow,
    /// as a fraction of takeoff speed.
    public var shallowTouchdownFactor: Double

    public init(
        thresholds: SportThresholds = SportThresholds.forSport(.wingfoil),
        entryFactor: Double = 1.0,
        exitFactor: Double = 0.88,
        minimumDuration: TimeInterval = 3,
        minimumTouchdown: TimeInterval = 1.5,
        shallowTouchdownWindow: TimeInterval = 5,
        shallowTouchdownFactor: Double = 0.7
    ) {
        self.thresholds = thresholds
        self.entryFactor = entryFactor
        self.exitFactor = exitFactor
        self.minimumDuration = minimumDuration
        self.minimumTouchdown = minimumTouchdown
        self.shallowTouchdownWindow = shallowTouchdownWindow
        self.shallowTouchdownFactor = shallowTouchdownFactor
    }

    public static func forSport(_ sport: Sport) -> FoilDetector {
        FoilDetector(
            thresholds: sport.thresholds,
            minimumDuration: sport.thresholds.minFlightDuration
        )
    }

    // MARK: - Detect

    public func detect(in track: Track) -> [Flight] {
        guard thresholds.foilTakeoffSpeed.isFinite, track.count >= 3 else { return [] }

        let hasMotion = track.points.contains { $0.verticalAccelSD != nil }

        // Per-sample flying decision.
        var flying = [Bool](repeating: false, count: track.count)
        var state = false
        let smoothnessBar = smoothnessBar(for: track)

        for i in 0..<track.count {
            let speed = track.speed[i]
            let smooth = track.points[i].verticalAccelSD.map { $0 <= smoothnessBar }

            if state {
                // Stay up until speed drops through the lower band, or the ride
                // gets rough again.
                let speedOK = speed >= thresholds.foilTakeoffSpeed * exitFactor
                let motionOK = smooth ?? true
                state = speedOK && motionOK
            } else {
                let speedOK = speed >= thresholds.foilTakeoffSpeed * entryFactor
                // With motion data, roughness vetoes a flight even at speed —
                // that is exactly the displacement-riding case speed alone gets
                // wrong. Without it, speed has to carry the decision alone.
                let motionOK = smooth ?? true
                state = speedOK && motionOK
            }
            flying[i] = state
        }

        // Close short touchdowns so a single rough sample does not split a
        // flight into two.
        var i = 0
        while i < flying.count {
            guard !flying[i] else { i += 1; continue }
            var j = i
            while j < flying.count, !flying[j] { j += 1 }
            let hasFlightBefore = i > 0 && flying[i - 1]
            let hasFlightAfter = j < flying.count && flying[j]
            let gap = j < flying.count
                ? track.elapsed[j] - track.elapsed[i]
                : Double.infinity
            // How far the dip actually went. A landing is deep; a lull is not.
            var deepest = Double.infinity
            if j <= flying.count { for k in i..<min(j, track.count) { deepest = min(deepest, track.speed[k]) } }
            let stayedShallow = deepest >= thresholds.foilTakeoffSpeed * shallowTouchdownFactor

            // Coming off the foil costs speed. If it never fell through the
            // exit band, the rider did not come down, whatever the
            // accelerometer made of it.
            //
            // This is what the roughness veto gets wrong on its own. A landing
            // from a jump, or a hard chop hit, reads 7 to 10 m/s² — three times
            // the bar — for a few seconds while the rider carries on at ten
            // knots. Six such spikes cut one continuous ride into seven
            // flights, and not one of the gaps had a single sample below
            // flying speed. Roughness is good evidence for *starting* a flight
            // and poor evidence for ending one.
            let neverSlowed = deepest >= thresholds.foilTakeoffSpeed * exitFactor

            let isLull = gap < minimumTouchdown
                || neverSlowed
                || (gap < shallowTouchdownWindow && stayedShallow)

            if hasFlightBefore, hasFlightAfter, isLull {
                for k in i..<j { flying[k] = true }
            }
            i = j
        }

        // Extract runs of `true` into flights.
        var flights: [Flight] = []
        i = 0
        while i < flying.count {
            guard flying[i] else { i += 1; continue }
            var j = i
            while j + 1 < flying.count, flying[j + 1] { j += 1 }

            let duration = track.elapsed[j] - track.elapsed[i]
            if duration >= minimumDuration, j > i {
                var maxSpeed = 0.0
                for k in i...j { maxSpeed = max(maxSpeed, track.speed[k]) }
                let distance = track.cumulativeDistance[j] - track.cumulativeDistance[i]

                flights.append(Flight(
                    id: flights.count,
                    startElapsed: track.elapsed[i],
                    endElapsed: track.elapsed[j],
                    startIndex: i,
                    endIndex: j,
                    distance: distance,
                    averageSpeed: duration > 0 ? distance / duration : 0,
                    maxSpeed: maxSpeed,
                    takeoffSpeed: track.speed[i],
                    landingSpeed: track.speed[j],
                    // A speed-only call is a guess with a physical basis; a call
                    // backed by motion data is close to a measurement.
                    confidence: hasMotion ? 0.9 : 0.55
                ))
            }
            i = j + 1
        }

        return flights
    }

    // MARK: - Summarise

    public func summarise(flights: [Flight], track: Track, movingTime: TimeInterval) -> FoilSummary {
        guard !flights.isEmpty else {
            return FoilSummary(
                flightCount: 0, timeOnFoil: 0, foilingFraction: 0, distanceOnFoil: 0,
                longestFlight: nil, fastestFlight: nil, averageFlightSpeed: 0,
                averageTakeoffSpeed: 0, touchdownCount: 0, timeToFirstFlight: nil,
                usedMotionData: track.points.contains { $0.verticalAccelSD != nil }
            )
        }

        let timeOnFoil = flights.reduce(0) { $0 + $1.duration }
        let distanceOnFoil = flights.reduce(0) { $0 + $1.distance }

        // Time to first flight is measured from when the rider started moving,
        // not from when they hit record — otherwise it just measures how long
        // they stood on the beach.
        let firstMoving = track.elapsed.indices.first {
            track.speed[$0] >= thresholds.movingSpeed
        }.map { track.elapsed[$0] }
        let timeToFirst = firstMoving.map { flights[0].startElapsed - $0 }

        return FoilSummary(
            flightCount: flights.count,
            timeOnFoil: timeOnFoil,
            foilingFraction: movingTime > 0 ? min(1, timeOnFoil / movingTime) : 0,
            distanceOnFoil: distanceOnFoil,
            longestFlight: flights.max { $0.duration < $1.duration },
            fastestFlight: flights.max { $0.maxSpeed < $1.maxSpeed },
            averageFlightSpeed: timeOnFoil > 0 ? distanceOnFoil / timeOnFoil : 0,
            averageTakeoffSpeed: flights.reduce(0) { $0 + $1.takeoffSpeed } / Double(flights.count),
            // Each flight after the first was preceded by a touchdown.
            touchdownCount: max(0, flights.count - 1),
            timeToFirstFlight: timeToFirst.map { max(0, $0) },
            usedMotionData: track.points.contains { $0.verticalAccelSD != nil }
        )
    }

    /// Per-sample flying flags, for shading the speed chart and the map.
    /// How rough the ride may be and still count as flying.
    ///
    /// The sport's figure, or a multiple of the session's own median if that is
    /// higher. It only ever loosens, which is the safe direction: speed is the
    /// primary test and this is a veto against being fast but still in the
    /// water. A veto tuned on a quiet rig becomes a blanket ban on a noisy one
    /// — a real parawing session had a median above the bar, so more than half
    /// of it could not be flying whatever the speed said, and one continuous
    /// ride came back as seventeen flights with sixteen touchdowns, not one of
    /// which dropped below eight knots.
    func smoothnessBar(for track: Track) -> Double {
        let energies = track.points.compactMap(\.verticalAccelSD).sorted()
        guard energies.count >= 8 else { return thresholds.foilSmoothnessSD }

        let low = energies[energies.count / 4]
        let median = energies[energies.count / 2]
        let high = energies[energies.count * 3 / 4]

        // Only a session with both quiet and rough phases gets the benefit.
        //
        // This is the whole safeguard. A rider who was flying some of the time
        // has two populations — quiet in the air, rough on the water — and the
        // bar belongs between them wherever the rig happens to read. A rider
        // planing the whole way has one population, and raising the bar to meet
        // it would call every fast sample a flight, which is exactly the false
        // positive the smoothness veto exists to prevent.
        guard high > low * Self.bimodalSpread else { return thresholds.foilSmoothnessSD }
        return max(thresholds.foilSmoothnessSD, median * thresholds.foilSmoothnessFraction)
    }

    /// How much wider the rough quarter has to be than the quiet quarter before
    /// a session counts as having both.
    static let bimodalSpread: Double = 1.5

    public func flyingMask(flights: [Flight], count: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: count)
        for f in flights {
            guard f.startIndex >= 0, f.endIndex < count else { continue }
            for i in f.startIndex...f.endIndex { mask[i] = true }
        }
        return mask
    }
}
