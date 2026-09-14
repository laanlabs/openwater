import Foundation

/// One wave ridden: a stretch where the water was doing the work and the
/// board was travelling the way the swell was going.
public struct WaveRide: Hashable, Sendable, Identifiable {

    public let id: Int
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int

    public let distance: Double
    public let entrySpeed: Double
    public let peakSpeed: Double
    public let averageSpeed: Double

    /// Mean degrees between the ride's course and the swell's direction of
    /// travel. Small is straight down the face; forty is down the line.
    public let offSwell: Double

    /// Degrees the ride made ground toward, takeoff to kick-out — always
    /// within `WaveRideFinder.halfAngle` of the swell's travel, which is the
    /// guarantee that every ride here went the way the waves were going.
    public let netBearing: Double

    /// Caught straight off the back of the ride before it — within the
    /// rise window of its kick-out, with no hole in the recording between.
    ///
    /// The rise test asks what the wave *gave* over the lull before it, and
    /// a rider who links waves never has a lull: the next face is under them
    /// before the last one's speed has gone. Such a ride is measured against
    /// the lull the *previous* wave rose out of — the speed was the wave's
    /// gift and it is still being ridden — and marked here, because linking
    /// is the thing a rider is trying to do.
    public let linked: Bool

    public var duration: TimeInterval { endElapsed - startElapsed }
    public var midIndex: Int { (startIndex + endIndex) / 2 }
}

/// A stretch on the foil that was not a wave: the pump between one wave
/// and the next, or out to a wave that never came. Only the sports that
/// paddle into waves have these — on a wing, flying without a wave is
/// sailing.
public struct PumpStretch: Hashable, Sendable, Identifiable {
    public let id: Int
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval
    public let startIndex: Int
    public let endIndex: Int
    public let distance: Double

    public var duration: TimeInterval { endElapsed - startElapsed }
}

/// A session's wave riding, taken as a whole.
public struct WaveRideSummary: Sendable {

    public let rides: [WaveRide]
    /// Every second on a wave, named ride or not.
    public let timeOnWaves: TimeInterval
    /// Every metre on a wave, named ride or not — the same population
    /// `timeOnWaves` counts, so the two can be printed side by side. It used
    /// to sum the named rides alone, which made the average speed a rider
    /// could work out from the pair quietly wrong.
    public let distance: Double
    public let longest: WaveRide?
    public let fastest: WaveRide?
    public let averageDuration: TimeInterval
    /// Degrees the swell comes from — the number every ride here is measured
    /// against.
    public let swellFrom: Double

    /// The speed a stretch had to hold to count, m/s.
    ///
    /// Reported because it is the one rule that can stop responding: it is
    /// the greater of the rider's pace fraction and an absolute floor, and
    /// below the floor the pace slider moves without changing anything. The
    /// rules sheet prints this so that is visible rather than mysterious.
    public let speedFloor: Double

    /// Whether the accelerometer was part of the judgement.
    ///
    /// False when the recording carries no motion channel — a phone in a
    /// pocket, an imported file — or when the rider has turned the quiet-deck
    /// rule off. Either way the rides were found from position alone, which
    /// is a weaker reading, and the screen says so rather than presenting
    /// both cases as the same answer. The glide detector carries the same
    /// admission per glide; here the inputs do not vary ride to ride, so
    /// neither does the answer.
    public let usedMotionData: Bool

    /// Every stretch on the foil that was not a wave — see `PumpStretch`.
    /// Empty except on the sports that paddle into waves.
    public var pumps: [PumpStretch] = []

    /// Seconds and metres spent pumping: the work between the waves, which
    /// on a paddled foil is the half of the sport the wave count leaves out.
    public var timePumping: TimeInterval { pumps.reduce(0) { $0 + $1.duration } }
    public var distancePumping: Double { pumps.reduce(0) { $0 + $1.distance } }

    public var count: Int { rides.count }

    /// Rides caught straight off the back of the one before.
    public var linkedCount: Int { rides.filter(\.linked).count }

    public static let none = WaveRideSummary(
        rides: [], timeOnWaves: 0, distance: 0,
        longest: nil, fastest: nil, averageDuration: 0, swellFrom: 0,
        speedFloor: 0, usedMotionData: false
    )
}

/// Finds the waves a rider caught, measured against the swell they set.
///
/// **Anchored on the swell, deliberately not the wind.** A wave day is
/// exactly the day the two disagree: a side-shore breeze over a groundswell
/// has the rider riding waves at right angles to the wind, and every
/// wind-anchored test — the glide detector's included — calls that riding
/// across. The swell arrow is the rider's own statement of which way the
/// waves were going, and it is the only signal that knows.
///
/// What makes a stretch a wave ride is otherwise the physics the glide
/// detector already settled: on the foil, at or above your own pace for the
/// day, not decelerating, accelerometer quiet where there is one — and the
/// speed *rose*, because a wave, like a bump, is the only thing out there
/// that gives you speed for nothing. This deliberately reuses those tested
/// pieces rather than re-deriving them; the one thing it changes is the axis.
///
/// Runs, legs and glides are untouched by all of this. Wave rides are a
/// reading of the same track, not a re-segmentation of it.
public struct WaveRideFinder {

    public var thresholds: SportThresholds

    /// Degrees either side of the swell's travel a ride may point.
    ///
    /// Straight down the face is 0°. Riding down the line — along the face,
    /// the way a rider outrunning the wave has to — sits around 40–60° off,
    /// so the cone is wide; past it the board is running along the trough or
    /// away over the back, and the wave is no longer what is carrying it.
    public static let halfAngle: Double = 65

    /// How much a wave has to add, as a fraction of the speed before it.
    ///
    /// Firmer than the glide detector's bar, which is set low so the gentle
    /// pump-and-glide of a SUP still registers. Catching a wave on a wing is
    /// not gentle — the face adds knots, not a rounding error — and at the
    /// glide bar plain GPS jitter on a long steady reach can read as a rise.
    public static let minimumGain: Double = 0.12

    /// How long a carve out of the cone a ride survives by default. Riding a
    /// face is not a straight line, and a turn up the wave points away for a
    /// second or two before it comes back.
    public static let bridgeSeconds: TimeInterval = 8

    /// The slowest a stretch may be and still be a ride, m/s, whatever the
    /// rider's pace fraction works out to.
    ///
    /// A floor exists because a fraction of a slow day is still slow, and
    /// drifting sideways at two knots is not a wave. It was a literal 3.0 for
    /// every sport, which is a wing rider's number: a prone surfer's entire
    /// ride happens under it, so their sessions came back empty and the pace
    /// slider — the control the screen tells them to reach for — did nothing.
    /// `forSport` lowers it for the sports ridden slowly, exactly as
    /// `DownwindAnalyzer.forSport` does for glides.
    public var minimumRideSpeed: Double = 3.0

    /// Whether a wave caught without touching down since the last one is
    /// *linked*, however long the pump between them took.
    ///
    /// The rise-window rule above marks a wave linked when it was caught
    /// within seconds of the last one's kick-out, which is what linking
    /// means on a downwinder: the next bump is under you or it is not. On a
    /// paddled foil in the surf the join is different in kind — the rider
    /// kicks out, turns, pumps back *out* through the trough for twenty or
    /// thirty seconds, and drops onto the next face without the board ever
    /// touching the water. That is the thing a SUP foiler is trying to do,
    /// and the whole session is judged by how many waves were strung
    /// together that way; by the rise-window rule not one of them counts.
    /// So for the sports that paddle into waves, staying on the foil is the
    /// link, and the pump is part of the ride between two waves.
    public var linksAcrossFlight = false

    /// Whether the deck is expected to be *rougher* on a wave than off it.
    ///
    /// The quiet-board rule was written for a wing: on the foil the chop
    /// stops, and a rattling deck at speed means the board is back on the
    /// water. A paddled foil in the surf reads the other way round. Paddling
    /// out is the quiet part — sitting on the board over a lull — and the
    /// ride is the rough part: the face, the carve, the pump. Measured on
    /// the first SUP-foil recording, the deck's vertical spread was 2–5
    /// m/s² paddling and 6–13 riding, so the rule, applied as written, threw
    /// out every wave in the session. Set, the accelerometer is not
    /// consulted here at all — the flights already used it to say where the
    /// foil was, which is the question it answers well.
    public var ridesAreRough = false

    /// Whether slowing down ends a ride.
    ///
    /// For a wing, decelerating through the cone means the wave has let go
    /// and the rider is cruising to a stop. On a wave face the speed is
    /// never steady: a bottom turn scrubs a knot and a half in two seconds
    /// and the next section gives it back, and a gate at a third of a metre
    /// per second per second fires on every one. What ends a paddled ride is
    /// the speed dropping below the floor, or the rider turning back out —
    /// both still tested.
    public var ridesSlowAndRecover = false

    /// Whether the direction of travel is consulted at all.
    ///
    /// For a wing the cone is the whole test: fast and pointed with the
    /// swell is a wave, fast and pointed anywhere else is the wind. A paddled
    /// foil has no wind to confuse it with — nothing but a wave gets it to
    /// riding speed — and a surfer rides *across* the face, down the line,
    /// with cutbacks through every point of the compass. A cone of any width
    /// was tried first: at 120° it found the first SUP-foil recording's
    /// waves only because the swell it inferred happened to point along
    /// them, and the moment the rider set the real swell, from the
    /// south-south-east, the same waves came out as five-second pieces.
    /// Set, a ride is a stretch on the foil at or above the floor, whatever
    /// it pointed at; the swell — the rider's or the inferred one — only
    /// labels how far off it each ride was.
    public var ignoresDirection = false

    /// Whether a ride is split where the rider pumped between two waves.
    ///
    /// With direction out of the rule, what separates two waves caught in
    /// one flight is the pump between them: the rider kicks out, turns, and
    /// works back through the trough well below the speed the wave gave,
    /// then drops onto the next face and the speed comes back. A stretch
    /// slower than `pumpFraction` of the wave's own typical speed for at
    /// least `minimumPump` ends the wave; the next rise is the next catch,
    /// and it is linked — same flight, never touched down. A bottom turn
    /// scrubs speed for a second or two and is left alone by the duration.
    /// Written from the rider's description of linking and pinned by no
    /// recording yet — the first SUP-foil recording has no linked waves.
    public var splitsAtPumps = false

    /// How far below the wave's own typical speed a pump sits.
    public static let pumpFraction: Double = 0.7

    /// How long a slow stretch has to last to be a pump rather than a turn.
    public static let minimumPump: TimeInterval = 4

    /// The cone this finder falls back to when the rider has not set one.
    public var defaultConeAngle: Double = WaveRideFinder.halfAngle

    /// The longest step between two fixes that can still be inside one ride.
    ///
    /// Widened to four sample intervals for a receiver reporting slowly; see
    /// where it is used for what it is defending against.
    public static let fixGapLimit: TimeInterval = 6

    /// The sibling analyzer whose judgement this borrows: the lull before a
    /// ride, what "quiet" means on this rig, and how hard a rider may be
    /// slowing and still be carried.
    private var glides: DownwindAnalyzer

    // MARK: The rules, as this rider has them

    /// Each of these is the rider's own answer where they have given one and
    /// the shared default where they have not. The wave rules were static
    /// constants and glide fields until a rider watched a thirty-second ride
    /// end five seconds early — eleven knots, twenty degrees off the swell,
    /// cut because the deck was rattling in short chop. What a wave *is*
    /// varies with the water and the board the way a glide does, so it is
    /// adjustable the same way, and every one of these still defaults to
    /// exactly what it was.

    /// Degrees either side of the swell's travel a ride may point.
    public var coneAngle: Double { thresholds.waveConeAngle ?? defaultConeAngle }

    /// The fraction of the rider's own with-the-swell pace a ride must hold.
    public var speedFraction: Double {
        thresholds.waveSpeedFraction ?? thresholds.glideSpeedFraction
    }

    /// What the wave has to add over the lull before it.
    public var minimumRise: Double {
        thresholds.waveMinimumGain ?? max(thresholds.glideMinimumGain, Self.minimumGain)
    }

    /// Shortest stretch worth naming a ride.
    public var shortestRide: TimeInterval {
        thresholds.waveMinimumDuration ?? thresholds.glideMinimumDuration
    }

    /// How long a carve out of the cone a ride survives.
    public var bridgeSeconds: TimeInterval {
        thresholds.waveBridgeSeconds ?? Self.bridgeSeconds
    }

    /// How noisy the deck may be, as a multiple of the session's own median.
    public var quietFraction: Double {
        thresholds.waveQuietFraction ?? thresholds.pumpEnergyFraction
    }

    /// Whether the accelerometer is consulted at all.
    public var consultsMotion: Bool {
        !ridesAreRough && quietFraction < SportThresholds.waveChopIgnored
    }

    /// How hard the rider may be slowing and still be counted as carried,
    /// m/s². The glide detector's own answer rather than a second copy of it,
    /// which is what this was: a literal that could not follow it.
    public var maximumDeceleration: Double { glides.maximumDeceleration }

    /// How far off the swell a *carve* may point while a ride is bridged
    /// across it.
    ///
    /// Wider than the cone by a quarter turn, because the whole point of the
    /// bridge is to tolerate a moment the per-sample test would refuse. It
    /// was a flat 90°, which is exactly the cone slider's maximum — so a
    /// rider who widened the cone all the way silently lost bridging
    /// altogether, at the setting most likely to have been reached for
    /// because rides were being cut in half.
    public var bridgeAngle: Double {
        bridgesAnyTurn ? 180 : min(120, max(90, coneAngle + 25))
    }

    /// Whether a carve may point *anywhere* and still be bridged.
    ///
    /// A wing rider who turns past a right angle to the swell has left it.
    /// A surfer turns past it on purpose several times a wave — the cutback
    /// swings the board back toward the breaking section and through the
    /// reverse of the swell's travel for two or three seconds — and on the
    /// first SUP-foil recording every long wave came out in three pieces,
    /// cut at each cutback. Set, a gap inside the carve tolerance is bridged
    /// whatever it pointed at, provided the rider stayed on the foil. What
    /// still ends a ride is a gap *longer* than that tolerance: pumping back
    /// out to the next wave takes far more than eight seconds, so it is the
    /// length of the excursion that tells a cutback from a kick-out, not its
    /// angle. A kick-out and re-catch inside eight seconds would read as one
    /// wave; it has not been seen in a real recording yet.
    public var bridgesAnyTurn = false

    public init(thresholds: SportThresholds = SportThresholds.forSport(.wingfoil)) {
        self.thresholds = thresholds
        self.glides = DownwindAnalyzer(thresholds: thresholds)
    }

    /// The finder for a sport, honouring the rider's own thresholds.
    ///
    /// The same shape as `DownwindAnalyzer.forSport`, and for the same
    /// reason: the sport decides how fast slow is, and a finder built from
    /// thresholds alone cannot know which sport they belong to.
    public static func forSport(
        _ sport: Sport, thresholds: SportThresholds? = nil
    ) -> WaveRideFinder {
        let rules = thresholds ?? sport.thresholds
        var finder = WaveRideFinder(thresholds: rules)
        finder.glides = DownwindAnalyzer.forSport(sport, thresholds: rules)
        switch sport {
        case .downwindSUP, .prone, .sup, .supFoil:
            // Paddled sports catch waves at speeds a wing rider would call
            // stopped. `DownwindAnalyzer` lowers its glide floor for the
            // first two; a SUP in the surf is the slowest thing this app
            // measures and belongs with them.
            finder.minimumRideSpeed = 2.5
        default:
            break
        }
        if sport.paddlesIntoWaves {
            // See each flag for what the surf does differently from a wing.
            finder.linksAcrossFlight = true
            finder.ridesAreRough = true
            finder.ridesSlowAndRecover = true
            finder.bridgesAnyTurn = true
            finder.ignoresDirection = true
            finder.splitsAtPumps = true
        }
        return finder
    }

    // MARK: - Which way the waves went, when nobody said

    /// Fewest seconds of riding the direction can be read from. Less than
    /// this and one wave, or one gust of jitter, is the whole vote.
    static let leastEvidenceForSwell: TimeInterval = 20

    /// The swell's *from* bearing, read off the rides themselves.
    ///
    /// Only for the sports that paddle into waves, where it is safe: a
    /// paddled board reaches riding speed on a wave face and nowhere else,
    /// so the direction the fast, flying samples travelled *is* the way the
    /// waves were going, and pumping back out — slower, and the other way —
    /// is outvoted by the rides it sits between. Speed-weighted so the
    /// riding does the voting. A wing rider's fast samples point wherever
    /// the wind sent them, which is why this is never used for one.
    ///
    /// Nil with too little evidence, and then the screen asks the rider,
    /// as it always did.
    public static func inferredSwell(
        in track: Track, flights: [Flight], thresholds: SportThresholds
    ) -> Double? {
        guard track.count > 1 else { return nil }
        let flyingMask = FoilDetector(thresholds: thresholds)
            .flyingMask(flights: flights, count: track.count)
        let floor = max(thresholds.movingSpeed * 2, thresholds.foilTakeoffSpeed * 0.8)
        var x = 0.0, y = 0.0, seconds = 0.0
        for i in 1..<track.count {
            let speed = track.speed[i]
            guard speed >= floor, flights.isEmpty || flyingMask[i] else { continue }
            let dt = min(track.elapsed[i] - track.elapsed[i - 1], 4 * track.sampleInterval)
            guard dt > 0 else { continue }
            let radians = track.course[i] * .pi / 180
            x += sin(radians) * speed * dt
            y += cos(radians) * speed * dt
            seconds += dt
        }
        guard seconds >= leastEvidenceForSwell, x != 0 || y != 0 else { return nil }
        let travel = Geo.normalizeDegrees(atan2(x, y) * 180 / .pi)
        return Geo.normalizeDegrees(travel + 180)
    }

    /// The swell a session's waves are measured against: the rider's own
    /// setting where there is one, and otherwise — for a sport that paddles
    /// into waves — the direction read off the rides.
    public static func swellFrom(
        for session: Session, flights: [Flight], thresholds: SportThresholds? = nil
    ) -> Double? {
        if let set = session.swellDirection { return set }
        guard session.sport.paddlesIntoWaves else { return nil }
        return inferredSwell(in: session.track, flights: flights,
                             thresholds: thresholds ?? session.sport.thresholds)
    }

    // MARK: - The rise

    /// Fewest fixes either window may be judged on, whatever the sample
    /// rate. Three is the least a median means anything with; a receiver
    /// reporting every five seconds gets its window stretched to reach them.
    private static let fewestInWindow = 3

    /// How far back the lull may be looked for when the fixes are sparse.
    private static let furthestLull: TimeInterval = 30

    /// How many of the trace's own sample-to-sample speed steps a rise has
    /// to be worth before it is believed.
    ///
    /// Measured on six real Doppler recordings the typical step is 0.12 to
    /// 0.25 m/s, the bumpiest downwinder at the top of that; four of those
    /// is half a metre a second to one, which is about what the twelve per
    /// cent bar already asks at riding speed, so on a clean trace this
    /// changes little. On a trace whose speed is derived from jittery
    /// positions the steps are two to eight times larger, and scanning a
    /// long candidate for a catch is scanning hundreds of noisy windows for
    /// the one that happened to be high — this is what stops that one from
    /// being called a wave.
    private static let stepsPerRise: Double = 4

    /// The trace's typical sample-to-sample speed step while moving: the
    /// median absolute difference, which jitter raises and a real wave does
    /// not, since a wave is a handful of steps among thousands.
    private func speedStep(in track: Track, breaks: [Bool]) -> Double {
        var steps: [Double] = []
        steps.reserveCapacity(track.count)
        for i in 1..<track.count where !breaks[i] {
            guard track.speed[i] >= thresholds.movingSpeed,
                  track.speed[i - 1] >= thresholds.movingSpeed else { continue }
            steps.append(abs(track.speed[i] - track.speed[i - 1]))
        }
        guard steps.count >= Self.fewestInWindow else { return 0 }
        return steps.sorted()[steps.count / 2]
    }

    /// The lull before a moment: the typical speed over the rise window
    /// before it. The median rather than the minimum the glide detector
    /// uses, because on a position-derived trace the minimum of eight
    /// jittery samples is the jitter. Nil when there is nothing to judge
    /// from — the recording starts here, or a hole ends here.
    private func lullBefore(_ index: Int, in track: Track, breaks: [Bool]) -> Double? {
        let start = track.elapsed[index] - DownwindAnalyzer.riseWindow
        let furthest = track.elapsed[index] - Self.furthestLull
        var speeds: [Double] = []
        var k = index
        while k > 0, !breaks[k],
              track.elapsed[k - 1] >= furthest,
              track.elapsed[k - 1] >= start || speeds.count < Self.fewestInWindow {
            k -= 1
            speeds.append(track.speed[k])
        }
        guard speeds.count >= Self.fewestInWindow else { return nil }
        return max(0.1, speeds.sorted()[speeds.count / 2])
    }

    /// How long a wave has to hold what it gave, seconds. Half the rise
    /// window, because a bump on a downwinder lifts the board for a few
    /// seconds before the rider drops off its back, and asking for eight
    /// seconds of lift lost a fifth of a real parawing run's waves.
    static let catchWindow: TimeInterval = 4

    /// What the wave gave at the catch: the typical speed over the catch
    /// window from a moment, or over the rest of the stretch if that is
    /// sooner. The median, so one lucky sample is not a wave.
    ///
    /// On a trace whose speed was *derived from positions* the judgement is
    /// harder to trust, and it is made more slowly: the lower quartile over
    /// the whole rise window, so the wave has to have lifted nearly every
    /// sample for eight seconds. Measured on six real Doppler recordings and
    /// on synthetic position jitter, the sample-to-sample speed steps of the
    /// bumpiest real downwinder and of half a metre of jitter are the same
    /// number — nothing in the speed's shape tells them apart. What does is
    /// where the speed came from. Doppler is a velocity measurement with a
    /// tenth of a metre a second of noise on it; a derived speed is the
    /// difference of two jittery positions and inherits all of it. The
    /// builder knows which it did, and the finder believes it.
    private func catchSpeed(from index: Int, to end: Int, in track: Track,
                            conservative: Bool) -> Double {
        let window = conservative ? DownwindAnalyzer.riseWindow : Self.catchWindow
        let limit = track.elapsed[index] + window
        var speeds: [Double] = []
        var k = index
        while k <= end, track.elapsed[k] <= limit || speeds.count < Self.fewestInWindow {
            speeds.append(track.speed[k])
            k += 1
        }
        let sorted = speeds.sorted()
        return conservative ? sorted[sorted.count / 4] : sorted[sorted.count / 2]
    }

    // MARK: - Pumps

    /// End a riding run wherever the rider pumped between waves — see
    /// `splitsAtPumps`.
    ///
    /// Each contiguous run is walked with a five-sample median of speed,
    /// against the median speed of the wave so far. A stretch below
    /// `pumpFraction` of that for at least `minimumPump` is cut out of the
    /// run; whatever rises out of it afterwards is a new wave, measured
    /// against the pump as its lull by the ordinary catch rule.
    private func breakAtPumps(_ riding: inout [Bool], in track: Track, breaks: [Bool]) {
        let count = track.count
        var index = 0
        while index < count {
            guard riding[index] else { index += 1; continue }
            var end = index
            while end + 1 < count, riding[end + 1], !breaks[end + 1] { end += 1 }
            defer { index = end + 1 }
            guard end > index else { continue }

            var waveSpeeds: [Double] = []
            var pumpStart: Int?
            var k = index
            while k <= end {
                let lo = max(index, k - 2), hi = min(end, k + 2)
                let local = track.speed[lo...hi].sorted()[(hi - lo) / 2]
                if waveSpeeds.count >= 3 {
                    let typical = waveSpeeds.sorted()[waveSpeeds.count / 2]
                    if local < typical * Self.pumpFraction {
                        if pumpStart == nil { pumpStart = k }
                        k += 1
                        continue
                    }
                }
                if let start = pumpStart {
                    if track.elapsed[k] - track.elapsed[start] >= Self.minimumPump {
                        // A pump: this wave ended where it began, and the
                        // rest of the run is judged as a wave of its own.
                        for cut in start..<k { riding[cut] = false }
                        waveSpeeds = []
                    }
                    pumpStart = nil
                }
                waveSpeeds.append(local)
                k += 1
            }
            if let start = pumpStart, track.elapsed[end] - track.elapsed[start] >= Self.minimumPump {
                for cut in start...end { riding[cut] = false }
            }
        }
    }

    // MARK: - Find

    /// The waves ridden, measured against `swellFrom` — degrees the swell
    /// comes from, as the rider set it.
    public func rides(
        in track: Track, flights: [Flight], swellFrom: Double
    ) -> WaveRideSummary {
        guard track.count >= 10 else { return .none }

        let travel = Geo.normalizeDegrees(swellFrom + 180)
        let hasMotion = consultsMotion && track.points.contains { $0.verticalAccelSD != nil }
        let flyingMask = FoilDetector(thresholds: thresholds)
            .flyingMask(flights: flights, count: track.count)
        let requiresFlight = !flights.isEmpty

        // Where the fixes stopped arriving.
        //
        // A run of samples is only a run of *time* while the receiver is
        // reporting. Drop out for a minute and the two samples either side
        // sit next to each other in the array, a minute apart on the water,
        // and nothing else here notices: the speed at both ends can clear the
        // floor, and an acceleration divided by a sixty-second step rounds to
        // nothing, so the deceleration gate waves it through. What came out
        // was one "wave" spanning the hole — twelve minutes long, at walking
        // pace, because the distance across a gap is not counted while the
        // duration across it is. A ride now ends where the recording does.
        let gapLimit = max(Self.fixGapLimit, 4 * track.sampleInterval)
        var breaksRide = [Bool](repeating: false, count: track.count)
        for i in 1..<track.count {
            breaksRide[i] = track.elapsed[i] - track.elapsed[i - 1] > gapLimit
        }

        // How much a rise has to be worth on *this* trace before it is
        // believed — see `stepsPerRise`.
        let riseFloor = Self.stepsPerRise * speedStep(in: track, breaks: breaksRide)
        // See `catchSpeed`: a speed that came from positions is judged more
        // slowly than one the receiver measured.
        let conservative = track.speedSource != .doppler

        // Smoothed acceleration, for the deceleration test — a single noisy
        // fix should not end a ride.
        //
        // Into its own array, not back over the input. Smoothing a series
        // into itself feeds each result into the next window, which is a
        // lagging cascade rather than the three-sample mean this is meant to
        // be; `DownwindAnalyzer.smooth` has always kept them separate and
        // this had drifted. The step across a dropout is left at zero rather
        // than divided by a minute.
        var raw = [Double](repeating: 0, count: track.count)
        for i in 1..<track.count {
            let dt = track.elapsed[i] - track.elapsed[i - 1]
            raw[i] = dt > 0 && !breaksRide[i] ? (track.speed[i] - track.speed[i - 1]) / dt : 0
        }
        var acceleration = raw
        for i in raw.indices {
            let lo = max(0, i - 1), hi = min(raw.count - 1, i + 1)
            acceleration[i] = raw[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }

        // The same median-relative bar the glide detector uses, on this
        // screen's own multiple of it.
        let energies = track.points.compactMap(\.verticalAccelSD).sorted()
        let quietEnergy = energies.isEmpty
            ? Double.infinity
            : energies[energies.count / 2] * quietFraction

        // The rider's own pace *with the swell*, so the floor measures wave
        // riding against wave riding — the same day-relative reasoning as the
        // glide floor, on this screen's own axis.
        var withSwell: [Double] = []
        var all: [Double] = []
        for i in 0..<track.count where track.speed[i] >= thresholds.movingSpeed {
            all.append(track.speed[i])
            if ignoresDirection || Geo.angleSeparation(track.course[i], travel) <= coneAngle {
                withSwell.append(track.speed[i])
            }
        }
        // A minute of riding with the swell before that median is trusted —
        // counted in seconds rather than in array entries, so a watch at one
        // fix a second and an imported file at one every five need the same
        // *evidence* rather than the same number of rows.
        let minuteOfFixes = max(10, Int((60 / max(0.1, track.sampleInterval)).rounded()))
        let sample = withSwell.count >= minuteOfFixes ? withSwell : all
        guard !sample.isEmpty else { return .none }
        let typical = sample.sorted()[sample.count / 2]
        let floor = max(minimumRideSpeed, speedFraction * typical)

        var riding = [Bool](repeating: false, count: track.count)
        for i in 0..<track.count {
            guard track.speed[i] >= floor else { continue }
            guard !requiresFlight || flyingMask[i] else { continue }
            guard ridesSlowAndRecover || acceleration[i] >= -maximumDeceleration else { continue }
            guard ignoresDirection || Geo.angleSeparation(track.course[i], travel) <= coneAngle else { continue }
            if hasMotion, let energy = track.points[i].verticalAccelSD {
                guard energy <= quietEnergy else { continue }
            }
            riding[i] = true
        }

        // Bridge the S-turns. Riding a face is not a straight line: a carve
        // up the wave points out of the cone for a second or two and back.
        // A gap is crossed only while the rider stays flying and never turns
        // properly away — past a right angle to the swell they have left it.
        var index = 0
        while index < track.count {
            guard riding[index] else { index += 1; continue }
            var end = index
            while end + 1 < track.count, riding[end + 1], !breaksRide[end + 1] { end += 1 }
            var next = end + 1
            while next < track.count, !riding[next] { next += 1 }
            guard next < track.count else { break }

            let bridgeable = track.elapsed[next] - track.elapsed[end] <= bridgeSeconds
                && ((end + 1)...next).allSatisfy { !breaksRide[$0] }
                && ((end + 1)..<next).allSatisfy { k in
                    (!requiresFlight || flyingMask[k])
                        && (ignoresDirection || Geo.angleSeparation(track.course[k], travel) <= bridgeAngle)
                }
            if bridgeable {
                for k in (end + 1)..<next { riding[k] = true }
            } else {
                index = next
            }
        }

        // See `splitsAtPumps`: a stretch well below the wave's own pace for
        // long enough is the pump to the next wave, not part of this one.
        if splitsAtPumps {
            breakAtPumps(&riding, in: track, breaks: breaksRide)
        }

        // Extract the rides.
        var out: [WaveRide] = []
        var timeOnWaves: TimeInterval = 0
        var distanceOnWaves = 0.0
        // The last wave accepted — where it ended, and the lull it rose out
        // of — so the next can be measured against that lull if it came
        // straight after. Named or not: a wave too short to name still gave
        // the speed the next one is carrying.
        var previous: (endIndex: Int, lull: Double)?
        index = 0
        while index < track.count {
            guard riding[index] else { index += 1; continue }
            var j = index
            while j + 1 < track.count, riding[j + 1], !breaksRide[j + 1] { j += 1 }
            defer { index = j + 1 }
            guard j > index else { continue }

            // The wave has to have *given* something: speed above the lull
            // before it. Cruising through the cone at one powered pace is a
            // reach that happens to point at the beach.
            //
            // Given it *at the catch*, and given it to the typical speed, not
            // to one sample. This was the peak of the whole stretch against
            // the slowest single fix in the eight seconds before it, and a
            // stretch can be minutes long once carves are bridged — so on a
            // trace whose speed is derived from jittery positions, a steady
            // run with the swell read as one three-hundred-second wave: the
            // lowest of eight noisy samples against the highest of three
            // hundred. A wave gives its speed when you drop in. So the
            // stretch is scanned for the moment the typical speed over the
            // next rise window beats the typical speed over the last one by
            // the bar, and the ride *begins there*: the cruise in the cone
            // before the wave arrived was riding by the per-sample rule, but
            // it was not the wave. A stretch with no such moment — a steady
            // pace, or jitter — is not a wave at all.
            //
            // Unless the lull never came. A wave caught straight off the back
            // of another — kicked out, turned, and onto the next face inside
            // the rise window — has the last wave's speed still under it, and
            // measured against the seconds just before it shows no rise at
            // all. That was how a good day lost half its waves. The lull it
            // is measured against is then the one the previous wave rose out
            // of: the speed was that wave's gift, and the rider never gave it
            // back. A hole in the recording between them breaks the chain —
            // what happened across a hole is not known, and a ride that
            // claims to have carried through one is a guess.
            var caughtAt: Int?
            var lull = 0.0
            var linked = false
            for k in index...j {
                var carried: Double?
                var carriedHere = false
                if let previous,
                   track.elapsed[k] - track.elapsed[previous.endIndex] <= DownwindAnalyzer.riseWindow,
                   !((previous.endIndex + 1)...k).contains(where: { breaksRide[$0] }) {
                    carried = previous.lull
                    carriedHere = true
                }
                let before = lullBefore(k, in: track, breaks: breaksRide)
                // No lull behind it — the recording starts here, or resumes
                // here after a hole — is no evidence of a rise. Saying nothing
                // is the honest answer.
                guard let candidateLull = [before, carried].compactMap({ $0 }).min() else { continue }
                let caught = catchSpeed(from: k, to: j, in: track, conservative: conservative)
                guard caught >= candidateLull * (1 + minimumRise),
                      caught - candidateLull >= riseFloor else { continue }
                caughtAt = k
                lull = candidateLull
                linked = carriedHere
                break
            }
            guard let start = caughtAt, start < j else { continue }
            index = start

            // See `linksAcrossFlight`: on a paddled foil the link is never
            // having touched down, whatever the pump between took.
            if linksAcrossFlight, !linked, let previous, requiresFlight,
               previous.endIndex < start,
               !((previous.endIndex + 1)...start).contains(where: { breaksRide[$0] }),
               (previous.endIndex...start).allSatisfy({ flyingMask[$0] }) {
                linked = true
            }

            let duration = track.elapsed[j] - track.elapsed[index]
            var peak = 0.0
            for k in index...j { peak = max(peak, track.speed[k]) }

            // And the ride as a whole went the way the waves were going —
            // takeoff to kick-out, not only sample by sample. The per-sample
            // cone nearly guarantees this, but the bridges tolerate a carve
            // up to a right angle off, and enough of them could add up to a
            // ride that wandered sideways. A wave carries you where it is
            // going; a ride that netted anywhere else was not one. Not asked
            // of a paddled foil, whose rides go along the face.
            let net = Geo.bearing(from: track.points[index].coordinate,
                                  to: track.points[j].coordinate)
            guard ignoresDirection || Geo.angleSeparation(net, travel) <= coneAngle else { continue }

            let distance = track.cumulativeDistance[j] - track.cumulativeDistance[index]
            timeOnWaves += duration
            distanceOnWaves += distance
            previous = (j, lull)
            guard duration >= shortestRide else { continue }

            var offSum = 0.0
            for k in index...j {
                offSum += Geo.angleSeparation(track.course[k], travel)
            }
            out.append(WaveRide(
                id: out.count,
                startElapsed: track.elapsed[index],
                endElapsed: track.elapsed[j],
                startIndex: index,
                endIndex: j,
                distance: distance,
                entrySpeed: track.speed[index],
                peakSpeed: peak,
                averageSpeed: duration > 0 ? distance / duration : 0,
                offSwell: offSum / Double(j - index + 1),
                netBearing: net,
                linked: linked
            ))
        }

        // Nothing found still answers with the floor it was looking for and
        // whether the accelerometer had a say. A rider on an empty screen is
        // owed the reason more than a rider looking at thirty rides is.
        var summary: WaveRideSummary
        if out.isEmpty {
            summary = WaveRideSummary(
                rides: [], timeOnWaves: timeOnWaves, distance: distanceOnWaves,
                longest: nil, fastest: nil, averageDuration: 0, swellFrom: swellFrom,
                speedFloor: floor, usedMotionData: hasMotion
            )
        } else {
            let named = out.reduce(0.0) { $0 + $1.duration }
            summary = WaveRideSummary(
                rides: out,
                timeOnWaves: timeOnWaves,
                distance: distanceOnWaves,
                longest: out.max { $0.duration < $1.duration },
                fastest: out.max { $0.peakSpeed < $1.peakSpeed },
                averageDuration: named / Double(out.count),
                swellFrom: swellFrom,
                speedFloor: floor,
                usedMotionData: hasMotion
            )
        }
        if splitsAtPumps, requiresFlight {
            summary.pumps = pumps(in: track, flying: flyingMask, riding: riding, breaks: breaksRide)
        }
        return summary
    }

    /// Shortest stretch worth calling a pump. A second of not-yet-riding
    /// at the very start of a catch is the catch, not a pump.
    static let shortestPump: TimeInterval = 2

    /// Every stretch on the foil that was not riding a wave, for the sports
    /// where that can only be pumping: between two linked waves, or out to
    /// a wave that never came, up to the moment the board touched down.
    private func pumps(in track: Track, flying: [Bool], riding: [Bool], breaks: [Bool]) -> [PumpStretch] {
        var out: [PumpStretch] = []
        var index = 0
        while index < track.count {
            guard flying[index], !riding[index] else { index += 1; continue }
            var end = index
            while end + 1 < track.count, flying[end + 1], !riding[end + 1], !breaks[end + 1] { end += 1 }
            defer { index = end + 1 }
            let duration = track.elapsed[end] - track.elapsed[index]
            guard duration >= Self.shortestPump else { continue }
            out.append(PumpStretch(
                id: out.count,
                startElapsed: track.elapsed[index],
                endElapsed: track.elapsed[end],
                startIndex: index,
                endIndex: end,
                distance: track.cumulativeDistance[end] - track.cumulativeDistance[index]
            ))
        }
        return out
    }
}
