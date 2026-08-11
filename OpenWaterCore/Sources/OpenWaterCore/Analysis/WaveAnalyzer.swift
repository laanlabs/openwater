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

    public var duration: TimeInterval { endElapsed - startElapsed }
    public var midIndex: Int { (startIndex + endIndex) / 2 }
}

/// A session's wave riding, taken as a whole.
public struct WaveRideSummary: Sendable {

    public let rides: [WaveRide]
    /// Every second on a wave, named ride or not.
    public let timeOnWaves: TimeInterval
    public let distance: Double
    public let longest: WaveRide?
    public let fastest: WaveRide?
    public let averageDuration: TimeInterval
    /// Degrees the swell comes from — the number every ride here is measured
    /// against.
    public let swellFrom: Double

    public var count: Int { rides.count }

    public static let none = WaveRideSummary(
        rides: [], timeOnWaves: 0, distance: 0,
        longest: nil, fastest: nil, averageDuration: 0, swellFrom: 0
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

    /// The sibling analyzer whose judgement this borrows: the lull before a
    /// ride, and what "quiet" means on this rig.
    private let glides: DownwindAnalyzer

    public init(thresholds: SportThresholds = SportThresholds.forSport(.wingfoil)) {
        self.thresholds = thresholds
        self.glides = DownwindAnalyzer(thresholds: thresholds)
    }

    // MARK: - Find

    /// The waves ridden, measured against `swellFrom` — degrees the swell
    /// comes from, as the rider set it.
    public func rides(
        in track: Track, flights: [Flight], swellFrom: Double
    ) -> WaveRideSummary {
        guard track.count >= 10 else { return .none }

        let travel = Geo.normalizeDegrees(swellFrom + 180)
        let hasMotion = track.points.contains { $0.verticalAccelSD != nil }
        let flyingMask = FoilDetector(thresholds: thresholds)
            .flyingMask(flights: flights, count: track.count)
        let requiresFlight = !flights.isEmpty

        // Smoothed acceleration, for the deceleration test — a single noisy
        // fix should not end a ride.
        var acceleration = [Double](repeating: 0, count: track.count)
        for i in 1..<track.count {
            let dt = track.elapsed[i] - track.elapsed[i - 1]
            acceleration[i] = dt > 0 ? (track.speed[i] - track.speed[i - 1]) / dt : 0
        }
        for i in acceleration.indices {
            let lo = max(0, i - 1), hi = min(acceleration.count - 1, i + 1)
            acceleration[i] = acceleration[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }

        let quietEnergy = glides.quietEnergyThreshold(in: track)

        // The rider's own pace *with the swell*, so the floor measures wave
        // riding against wave riding — the same day-relative reasoning as the
        // glide floor, on this screen's own axis.
        var withSwell: [Double] = []
        var all: [Double] = []
        for i in 0..<track.count where track.speed[i] >= thresholds.movingSpeed {
            all.append(track.speed[i])
            if Geo.angleSeparation(track.course[i], travel) <= Self.halfAngle {
                withSwell.append(track.speed[i])
            }
        }
        let sample = withSwell.count >= 60 ? withSwell : all
        guard !sample.isEmpty else { return .none }
        let typical = sample.sorted()[sample.count / 2]
        let floor = max(3.0, thresholds.glideSpeedFraction * typical)

        var riding = [Bool](repeating: false, count: track.count)
        for i in 0..<track.count {
            guard track.speed[i] >= floor else { continue }
            guard !requiresFlight || flyingMask[i] else { continue }
            guard acceleration[i] >= -0.35 else { continue }
            guard Geo.angleSeparation(track.course[i], travel) <= Self.halfAngle else { continue }
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
            while end + 1 < track.count, riding[end + 1] { end += 1 }
            var next = end + 1
            while next < track.count, !riding[next] { next += 1 }
            guard next < track.count else { break }

            let bridgeable = track.elapsed[next] - track.elapsed[end] <= 8
                && ((end + 1)..<next).allSatisfy { k in
                    (!requiresFlight || flyingMask[k])
                        && Geo.angleSeparation(track.course[k], travel) <= 90
                }
            if bridgeable {
                for k in (end + 1)..<next { riding[k] = true }
            } else {
                index = next
            }
        }

        // Extract the rides.
        var out: [WaveRide] = []
        var timeOnWaves: TimeInterval = 0
        index = 0
        while index < track.count {
            guard riding[index] else { index += 1; continue }
            var j = index
            while j + 1 < track.count, riding[j + 1] { j += 1 }
            defer { index = j + 1 }
            guard j > index else { continue }

            let duration = track.elapsed[j] - track.elapsed[index]
            var peak = 0.0
            for k in index...j { peak = max(peak, track.speed[k]) }

            // The wave has to have *given* something: speed above the lull
            // before it. Cruising through the cone at one powered pace is a
            // reach that happens to point at the beach.
            let rose = peak >= glides.troughBefore(index, in: track)
                * (1 + max(thresholds.glideMinimumGain, Self.minimumGain))
            guard rose else { continue }

            // And the ride as a whole went the way the waves were going —
            // takeoff to kick-out, not only sample by sample. The per-sample
            // cone nearly guarantees this, but the bridges tolerate a carve
            // up to a right angle off, and enough of them could add up to a
            // ride that wandered sideways. A wave carries you where it is
            // going; a ride that netted anywhere else was not one.
            let net = Geo.bearing(from: track.points[index].coordinate,
                                  to: track.points[j].coordinate)
            guard Geo.angleSeparation(net, travel) <= Self.halfAngle else { continue }

            timeOnWaves += duration
            guard duration >= thresholds.glideMinimumDuration else { continue }

            var offSum = 0.0
            for k in index...j {
                offSum += Geo.angleSeparation(track.course[k], travel)
            }
            let distance = track.cumulativeDistance[j] - track.cumulativeDistance[index]
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
                netBearing: net
            ))
        }

        guard !out.isEmpty else { return .none }
        let named = out.reduce(0.0) { $0 + $1.duration }
        return WaveRideSummary(
            rides: out,
            timeOnWaves: timeOnWaves,
            distance: out.reduce(0) { $0 + $1.distance },
            longest: out.max { $0.duration < $1.duration },
            fastest: out.max { $0.peakSpeed < $1.peakSpeed },
            averageDuration: named / Double(out.count),
            swellFrom: swellFrom
        )
    }
}
