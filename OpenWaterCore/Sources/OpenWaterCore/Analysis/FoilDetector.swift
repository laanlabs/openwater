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

    /// Sample ranges inside this flight where the speed dropped out of the
    /// flying band but the rider never came off.
    ///
    /// A flight is what a rider counts as one ride; a dip is a moment inside
    /// it. Both are true and they answer different questions, so both are
    /// kept. "How many rides did I get" reads the flights; "was I up at this
    /// instant" — the speed chart's shading, a gybe asking whether it stayed
    /// dry — subtracts these.
    ///
    /// Empty for a flight that was never joined, which is most of them.
    public var dips: [ClosedRange<Int>] = []

    public var duration: TimeInterval { endElapsed - startElapsed }

    public init(
        id: Int, startElapsed: TimeInterval, endElapsed: TimeInterval,
        startIndex: Int, endIndex: Int,
        distance: Double, averageSpeed: Double, maxSpeed: Double,
        takeoffSpeed: Double, landingSpeed: Double, confidence: Double,
        dips: [ClosedRange<Int>] = []
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
        self.dips = dips
    }

    /// Seconds inside this flight that the rider spent out of the flying band.
    public func dippedSeconds(in track: Track) -> TimeInterval {
        dips.reduce(0) { total, dip in
            guard dip.lowerBound >= 0, dip.upperBound < track.count else { return total }
            return total + (track.elapsed[dip.upperBound] - track.elapsed[dip.lowerBound])
        }
    }

    // MARK: - Coding

    /// Hand-written for one line of it: `dips` has to be optional on the way
    /// in.
    ///
    /// A synthesised `Decodable` ignores property defaults and throws
    /// `keyNotFound` — so adding this field with an `= []` default silently
    /// made every archive and every stored summary written before it
    /// undecodable. It fails at the top: the whole session refuses to load,
    /// which reads as an empty library rather than as a new field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        startElapsed = try c.decode(TimeInterval.self, forKey: .startElapsed)
        endElapsed = try c.decode(TimeInterval.self, forKey: .endElapsed)
        startIndex = try c.decode(Int.self, forKey: .startIndex)
        endIndex = try c.decode(Int.self, forKey: .endIndex)
        distance = try c.decode(Double.self, forKey: .distance)
        averageSpeed = try c.decode(Double.self, forKey: .averageSpeed)
        maxSpeed = try c.decode(Double.self, forKey: .maxSpeed)
        takeoffSpeed = try c.decode(Double.self, forKey: .takeoffSpeed)
        landingSpeed = try c.decode(Double.self, forKey: .landingSpeed)
        confidence = try c.decode(Double.self, forKey: .confidence)
        dips = try c.decodeIfPresent([ClosedRange<Int>].self, forKey: .dips) ?? []
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

    /// How long a rider needs to fall, swim to the board and get back up.
    ///
    /// Everything above is about the shape of the speed trace. This is about
    /// the rider, and it is the one that a rider can simply tell us:
    ///
    /// > a person would not fall for just a second or two — it takes like at
    /// > least 20 - 30 seconds to fall and get back up
    ///
    /// Below this, two flights are not two flights. Whatever happened between
    /// them — a lull, a bad patch of fixes, a moment of sinking off the foil
    /// and pumping straight back onto it — the rider did not go swimming and
    /// come back, because there is not enough time in it. Measured on a
    /// reported parawing run: one continuous ride, thirty "flights", and
    /// twenty-four of the twenty-nine gaps between them under twenty seconds.
    ///
    /// This joins for *counting*. What happened moment to moment is kept on
    /// `Flight.dips` and is not touched.
    public var minimumRecovery: TimeInterval

    public init(
        thresholds: SportThresholds = SportThresholds.forSport(.wingfoil),
        entryFactor: Double = 1.0,
        exitFactor: Double = 0.88,
        minimumDuration: TimeInterval = 3,
        minimumTouchdown: TimeInterval = 1.5,
        shallowTouchdownWindow: TimeInterval = 5,
        shallowTouchdownFactor: Double = 0.7,
        minimumRecovery: TimeInterval = 20
    ) {
        self.thresholds = thresholds
        self.entryFactor = entryFactor
        self.exitFactor = exitFactor
        self.minimumDuration = minimumDuration
        self.minimumTouchdown = minimumTouchdown
        self.shallowTouchdownWindow = shallowTouchdownWindow
        self.shallowTouchdownFactor = shallowTouchdownFactor
        self.minimumRecovery = minimumRecovery
    }

    public static func forSport(_ sport: Sport) -> FoilDetector {
        FoilDetector(
            thresholds: sport.thresholds,
            minimumDuration: sport.thresholds.minFlightDuration,
            minimumRecovery: sport.thresholds.foilMinimumRecovery
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

        return join(flights, in: track)
    }

    /// Merge flights separated by less time than a fall takes.
    ///
    /// The pass above decides, sample by sample, whether the board is out of
    /// the water — and it is good at that. This is a different question, and
    /// the one a rider is actually asking when they read "30 flights": how
    /// many times did I get up? A four-second drop out of the flying band on
    /// a bumpy downwind run is not a ride ending and another beginning. It is
    /// the trough between two bumps.
    ///
    /// The gap is not thrown away. It becomes a dip on the joined flight, so
    /// the speed chart still shades it as off-foil and a gybe through it
    /// still counts as wet. This is the whole design: one flight, and the
    /// moments inside it still told honestly. Merging the two — letting the
    /// join rewrite the instantaneous answer as well as the count — is what
    /// made a gybe that dipped to three and a half knots score as dry.
    func join(_ flights: [Flight], in track: Track) -> [Flight] {
        guard minimumRecovery > 0, flights.count > 1 else { return flights }

        var joined: [Flight] = []
        for flight in flights {
            guard var previous = joined.last,
                  flight.startElapsed - previous.endElapsed < minimumRecovery
            else {
                joined.append(flight)
                continue
            }

            var dips = previous.dips + flight.dips
            if flight.startIndex > previous.endIndex {
                dips.append(previous.endIndex...flight.startIndex)
            }

            let duration = flight.endElapsed - previous.startElapsed
            let distance = track.cumulativeDistance[flight.endIndex]
                - track.cumulativeDistance[previous.startIndex]

            previous = Flight(
                id: previous.id,
                startElapsed: previous.startElapsed,
                endElapsed: flight.endElapsed,
                startIndex: previous.startIndex,
                endIndex: flight.endIndex,
                distance: distance,
                averageSpeed: duration > 0 ? distance / duration : 0,
                maxSpeed: max(previous.maxSpeed, flight.maxSpeed),
                // The takeoff that started the ride, and the landing that
                // ended it. The ones in between were never landings.
                takeoffSpeed: previous.takeoffSpeed,
                landingSpeed: flight.landingSpeed,
                confidence: min(previous.confidence, flight.confidence),
                dips: dips
            )
            joined[joined.count - 1] = previous
        }

        // Ids are a position in this list, and the list just got shorter.
        return joined.enumerated().map { index, flight in
            Flight(
                id: index,
                startElapsed: flight.startElapsed, endElapsed: flight.endElapsed,
                startIndex: flight.startIndex, endIndex: flight.endIndex,
                distance: flight.distance, averageSpeed: flight.averageSpeed,
                maxSpeed: flight.maxSpeed, takeoffSpeed: flight.takeoffSpeed,
                landingSpeed: flight.landingSpeed, confidence: flight.confidence,
                dips: flight.dips
            )
        }
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

        // Dips come out. A joined flight spans its own troughs, and counting
        // them as time on foil would inflate the headline number by exactly
        // the seconds the rider was not on it.
        let dipped = flights.reduce(0) { $0 + $1.dippedSeconds(in: track) }
        let timeOnFoil = max(0, flights.reduce(0) { $0 + $1.duration } - dipped)
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

    /// Was the rider up at this instant?
    ///
    /// Not the same question as "how many flights", and this is the one that
    /// has to stay literal. Everything reading it — the speed chart's
    /// shading, the map's colours, whether a gybe stayed dry, whether a glide
    /// counts — is asking about a moment rather than about a ride, so a
    /// flight's dips are subtracted back out.
    public func flyingMask(flights: [Flight], count: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: count)
        guard count > 0 else { return mask }
        for f in flights {
            // Clamped, not dropped. A flight whose end sits on the last
            // sample is an ordinary session that stopped recording while
            // still flying; dropping it silently erased the whole flight
            // from the mask rather than trimming one index off it.
            let first = max(0, f.startIndex)
            let last = min(count - 1, f.endIndex)
            guard first <= last else { continue }
            for i in first...last { mask[i] = true }

            for dip in f.dips {
                let from = max(0, dip.lowerBound)
                let to = min(count - 1, dip.upperBound)
                guard from <= to else { continue }
                // The ends of the dip are the last flying sample and the
                // first flying sample after it, so only the interior is down.
                guard from + 1 <= to - 1 else { continue }
                for i in (from + 1)...(to - 1) { mask[i] = false }
            }
        }
        return mask
    }
}
