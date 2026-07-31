import Foundation

/// One fixed-distance slice of a session.
///
/// The classic running-watch split, which turns out to be just as useful on the
/// water for anything that goes in a line — a downwinder, a crossing, a long
/// reach. It answers the question a track heatmap cannot: *was I getting
/// faster or slower as it went on?*
public struct Split: Hashable, Sendable, Codable, Identifiable {

    /// 1-based, the way a rider counts them.
    public let number: Int

    /// Metres in this split. The last one is usually short.
    public let distance: Double

    /// Distance from the start of the session to the end of this split.
    public let cumulativeDistance: Double

    public let duration: TimeInterval
    public let averageSpeed: Double
    public let maxSpeed: Double
    public let averageHeartRate: Double?

    /// Elapsed time at the start and end of the split, for cross-referencing
    /// with the map and the charts.
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public var id: Int { number }

    /// Whether the split ran the full distance. A partial last split has a real
    /// average but should not be compared with the others as an equal.
    public let isComplete: Bool

    public init(
        number: Int,
        distance: Double,
        cumulativeDistance: Double,
        duration: TimeInterval,
        averageSpeed: Double,
        maxSpeed: Double,
        averageHeartRate: Double?,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isComplete: Bool
    ) {
        self.number = number
        self.distance = distance
        self.cumulativeDistance = cumulativeDistance
        self.duration = duration
        self.averageSpeed = averageSpeed
        self.maxSpeed = maxSpeed
        self.averageHeartRate = averageHeartRate
        self.startTime = startTime
        self.endTime = endTime
        self.isComplete = isComplete
    }
}

/// Cuts a track into fixed-distance splits.
///
/// The boundaries are interpolated *within* the sample they fall in rather than
/// snapped to the nearest fix. At 8 m/s a one-second sample is eight metres, so
/// snapping would move a kilometre marker by up to that much and put a
/// systematic wobble into every split time — small, but exactly the kind of
/// error that makes a rider distrust a table of numbers that should be simple.
public enum SplitAnalyzer {

    public static func splits(of track: Track, every metres: Double) -> [Split] {
        guard metres > 0, track.count > 1, track.totalDistance > 0 else { return [] }

        var result: [Split] = []
        var splitStartTime: TimeInterval = 0
        var splitStartDistance: Double = 0
        var number = 1

        var maxSpeed = track.speed.first ?? 0
        var heartRateSum = 0.0
        var heartRateCount = 0

        var target = metres

        for index in 1..<track.count {
            maxSpeed = max(maxSpeed, track.speed[index])
            if let heartRate = track.points[index].heartRate {
                heartRateSum += heartRate
                heartRateCount += 1
            }

            // A single sample can span more than one boundary if the receiver
            // dropped out, so this has to be a loop rather than an if.
            while track.cumulativeDistance[index] >= target {
                let previousDistance = track.cumulativeDistance[index - 1]
                let segment = track.cumulativeDistance[index] - previousDistance
                let fraction = segment > 0 ? (target - previousDistance) / segment : 0
                let crossingTime = track.elapsed[index - 1]
                    + (track.elapsed[index] - track.elapsed[index - 1]) * fraction

                let duration = crossingTime - splitStartTime
                let covered = target - splitStartDistance

                result.append(Split(
                    number: number,
                    distance: covered,
                    cumulativeDistance: target,
                    duration: duration,
                    averageSpeed: duration > 0 ? covered / duration : 0,
                    maxSpeed: maxSpeed,
                    averageHeartRate: heartRateCount > 0 ? heartRateSum / Double(heartRateCount) : nil,
                    startTime: splitStartTime,
                    endTime: crossingTime,
                    isComplete: true
                ))

                number += 1
                splitStartTime = crossingTime
                splitStartDistance = target
                target += metres
                maxSpeed = track.speed[index]
                heartRateSum = 0
                heartRateCount = 0
            }
        }

        // Whatever is left over. Reported rather than dropped: a rider who did
        // 7.7 km wants to see the 700 m, and hiding it makes the totals in the
        // table disagree with the totals everywhere else in the app.
        let remaining = track.totalDistance - splitStartDistance
        if remaining > 1 {
            let duration = track.duration - splitStartTime
            result.append(Split(
                number: number,
                distance: remaining,
                cumulativeDistance: track.totalDistance,
                duration: duration,
                averageSpeed: duration > 0 ? remaining / duration : 0,
                maxSpeed: maxSpeed,
                averageHeartRate: heartRateCount > 0 ? heartRateSum / Double(heartRateCount) : nil,
                startTime: splitStartTime,
                endTime: track.duration,
                isComplete: false
            ))
        }

        return result
    }
}

extension Session {
    /// Splits at the given interval, computed on demand — they are cheap and
    /// depend on a unit choice the rider can change, so they are not cached in
    /// the summary.
    public func splits(every metres: Double) -> [Split] {
        SplitAnalyzer.splits(of: track, every: metres)
    }
}
