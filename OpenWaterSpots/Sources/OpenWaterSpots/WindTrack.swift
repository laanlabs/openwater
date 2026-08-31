import Foundation
import OpenWaterCore

// MARK: - The track

/// The wind ahead as one continuous strip: quarter-hour steps while a
/// rapid-update model still has them, hourly consensus after.
///
/// Two cards used to draw this — six hours at fifteen-minute grain, then a
/// day at hourly — which put the same wind on the screen twice at two
/// scales and left the rider to join them up. One strip with a change of
/// grain says it once. Every step carries the minutes it stands for, so the
/// axis stays linear in time straight through the handover: a quarter-hour
/// column is a quarter the width of an hourly one, and the detail near now
/// costs nothing in honesty.
public struct WindTrack: Sendable {

    public struct Step: Identifiable, Sendable {
        public let id: Int
        public let at: Date
        public let speedKn: Double?
        public let gustKn: Double?
        /// Degrees the wind comes from.
        public let directionDeg: Double?
        /// How much time this column stands for — its width, in effect.
        public let minutes: Double
        /// Whether this step wears the labels: the hour, the arrow and the
        /// two numbers. Four labels an hour is noise, not detail.
        public let isHourMark: Bool
    }

    public var steps: [Step] = []
    public var timeZone: TimeZone?
    /// Where the quarter-hour data hands over to the hourly consensus. Nil
    /// when the strip is one grain the whole way — which is most of the
    /// world, since the rapid-update models are regional.
    public var handover: Int?

    public var isEmpty: Bool { !steps.contains { $0.speedKn != nil } }

    /// Full scale, gusts folded in — the caps have to fit under the same
    /// grid the bars are read against.
    public var peakKn: Double {
        max(steps.flatMap { [$0.speedKn, $0.gustKn] }.compactMap { $0 }.max() ?? 1, 1)
    }

    /// Quarter-hour steps up to where they run out, then the hours that
    /// come after them.
    ///
    /// The two feeds overlap by design — the quarter-hour models publish
    /// six hours the hourly one also has — so the hourly side starts
    /// strictly after the last fine step rather than at its own first hour.
    public static func make(nearTerm: NearTermWind, outlook: WindOutlook,
                     at now: Date = Date()) -> WindTrack {
        let zone = nearTerm.timeZone ?? outlook.timeZone
        var calendar = Calendar.current
        if let zone { calendar.timeZone = zone }

        var steps: [Step] = []
        // The quarter-hour run starts at the top of its own hour, so its
        // first steps can already be behind now. A strip that opens on a
        // moment that has been and gone is the one thing it must not do;
        // the step in progress stays, because it is this quarter hour.
        let current = now.addingTimeInterval(-15 * 60)
        for index in nearTerm.times.indices where nearTerm.times[index] >= current {
            let at = nearTerm.times[index]
            steps.append(Step(id: steps.count, at: at,
                              speedKn: nearTerm.speedsKn[safe: index] ?? nil,
                              gustKn: nearTerm.gustsKn[safe: index] ?? nil,
                              directionDeg: nearTerm.directions[safe: index] ?? nil,
                              minutes: 15,
                              isHourMark: calendar.component(.minute, from: at) == 0))
        }
        let fine = steps.count

        // Independent models only, matching the consensus the bars draw.
        let consensus = outlook.consensus
        let gusts = outlook.consensusGusts
        let directions = outlook.blendDirections(
            of: Set(outlook.models.filter { !$0.isComposite }.map(\.id)))
        // With no fine steps at all, the hour in progress is still the hour
        // to open on — hence an hour back rather than now.
        let after = steps.last?.at ?? now.addingTimeInterval(-3600)
        for hour in outlook.hours.indices where outlook.hours[hour] > after {
            steps.append(Step(id: steps.count, at: outlook.hours[hour],
                              speedKn: consensus[safe: hour] ?? nil,
                              gustKn: gusts[safe: hour] ?? nil,
                              directionDeg: directions[safe: hour] ?? nil,
                              minutes: 60, isHourMark: true))
        }

        return WindTrack(steps: steps, timeZone: zone,
                         handover: (fine > 0 && fine < steps.count) ? fine : nil)
    }
}

/// Bounds-checked indexing, for reading model arrays that may be short.
///
/// The forecast endpoints are free to answer with fewer hours than were
/// asked for, and a strip that traps on a thin reply is worse than one with
/// a gap in it.
extension Array {
    public subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
