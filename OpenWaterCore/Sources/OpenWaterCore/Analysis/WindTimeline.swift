import Foundation

/// Wind over the hours of a session, held as vectors.
///
/// A session's `Wind` is one number, and a three-hour downwinder through a
/// sea-breeze onset is not one number — the estimator's own comment admits
/// as much. This is the richer record: a handful of timestamped samples,
/// usually one per hour from a weather model's archive, kept alongside the
/// rider's own call rather than instead of it. The rider's `Wind` stays the
/// truth the analysis runs on; this is the model's account of the day, ready
/// for the analyzers to consult per-moment once they learn how.
///
/// Everything here works in components. `u` is the eastward part, `v` the
/// northward, both m/s, with the meteorological sign convention: a northerly
/// (wind *from* 0°) has `u == 0, v == -speed`. Interpolating and averaging
/// components is what makes 350° and 10° neighbours instead of opposites —
/// a plain mean of those two bearings is 180°, due south, the exact reverse
/// of what both samples said.
public struct WindTimeline: Hashable, Sendable, Codable {

    /// One moment's wind.
    public struct Sample: Hashable, Sendable, Codable {

        public var time: Date

        /// Eastward component, m/s. `u = -speed * sin(directionFrom)`.
        public var u: Double

        /// Northward component, m/s. `v = -speed * cos(directionFrom)`.
        public var v: Double

        /// Gust, m/s, when the source gave one. Never inferred.
        public var gust: Double?

        public init(time: Date, u: Double, v: Double, gust: Double? = nil) {
            self.time = time
            self.u = u
            self.v = v
            self.gust = gust
        }

        /// From the numbers a forecast actually says: a speed and the
        /// direction the wind comes from.
        public init(time: Date, speed: Double, directionFrom: Double, gust: Double? = nil) {
            let theta = directionFrom * .pi / 180
            self.init(time: time, u: -speed * sin(theta), v: -speed * cos(theta), gust: gust)
        }

        public var speed: Double { (u * u + v * v).squareRoot() }

        /// Degrees the wind comes from, 0..<360. Meaningless near calm —
        /// callers showing an arrow should check `speed` first.
        public var directionFrom: Double {
            Geo.normalizeDegrees(atan2(-u, -v) * 180 / .pi)
        }
    }

    /// Samples in time order. Usually hourly, never assumed to be.
    public private(set) var samples: [Sample]

    public init(samples: [Sample]) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// The stretch of time the samples actually cover.
    public var span: DateInterval? {
        guard let first = samples.first, let last = samples.last else { return nil }
        return DateInterval(start: first.time, end: last.time)
    }

    /// How far past the first and last sample a question is still answered.
    /// Hourly data speaks for the half hour either side of each reading;
    /// three quarters of an hour keeps a session that starts just before the
    /// first archive hour from reading as unknown wind.
    public static let slack: TimeInterval = 45 * 60

    // MARK: - Reading

    /// The wind at a moment, interpolated in components between the two
    /// bracketing samples. Beyond the ends the nearest sample answers, up to
    /// `slack`; further than that is honestly `nil` rather than a guess.
    public func wind(at date: Date) -> Sample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if date <= first.time {
            return date >= first.time.addingTimeInterval(-Self.slack)
                ? Sample(time: date, u: first.u, v: first.v, gust: first.gust) : nil
        }
        if date >= last.time {
            return date <= last.time.addingTimeInterval(Self.slack)
                ? Sample(time: date, u: last.u, v: last.v, gust: last.gust) : nil
        }
        // First sample at or past the date; its predecessor brackets from below.
        guard let upper = samples.firstIndex(where: { $0.time >= date }) else { return nil }
        let b = samples[upper]
        guard upper > 0 else { return Sample(time: date, u: b.u, v: b.v, gust: b.gust) }
        let a = samples[upper - 1]
        let width = b.time.timeIntervalSince(a.time)
        guard width > 0 else { return Sample(time: date, u: b.u, v: b.v, gust: b.gust) }
        let t = date.timeIntervalSince(a.time) / width
        // Gust is not a vector; between two readings the honest interpolation
        // is still linear, and a one-sided gust reads through unchanged.
        let gust: Double? = switch (a.gust, b.gust) {
        case let (ga?, gb?): ga + (gb - ga) * t
        case let (ga?, nil): ga
        case let (nil, gb?): gb
        case (nil, nil): nil
        }
        return Sample(
            time: date,
            u: a.u + (b.u - a.u) * t,
            v: a.v + (b.v - a.v) * t,
            gust: gust
        )
    }

    /// The window collapsed to the one number the rest of the app runs on.
    ///
    /// Direction comes off the mean vector, which is what makes it
    /// speed-weighted: a 2 kn zephyr does not out-vote a 20 kn breeze about
    /// which way the day blew. Speed is the mean of the sampled speeds, not
    /// the length of the mean vector — a shifty day averages to a short
    /// vector, and reporting that as the strength would call a gusty 15 kn
    /// afternoon a drifter. Gust is the biggest one seen: "gusting 25" is a
    /// fact about the day's worst moment, not its average.
    ///
    /// `nil` when no samples fall near the window, or when the mean vector
    /// is too short to point anywhere — near calm, direction is noise, and
    /// the guide's rule is to say nothing rather than guess (§5.2).
    public func averaged(
        over interval: DateInterval,
        source: Wind.Source = .external,
        confidence: Double = 0.7
    ) -> Wind? {
        var chosen = samples.filter {
            $0.time >= interval.start.addingTimeInterval(-Self.slack)
                && $0.time <= interval.end.addingTimeInterval(Self.slack)
        }
        // A window shorter than the sampling gap can fall between readings;
        // the moment in the middle of it is still answerable.
        if chosen.isEmpty, let mid = wind(at: interval.start.addingTimeInterval(interval.duration / 2)) {
            chosen = [mid]
        }
        guard !chosen.isEmpty else { return nil }

        let meanU = chosen.reduce(0) { $0 + $1.u } / Double(chosen.count)
        let meanV = chosen.reduce(0) { $0 + $1.v } / Double(chosen.count)
        guard (meanU * meanU + meanV * meanV).squareRoot() > 0.1 else { return nil }

        let meanSpeed = chosen.reduce(0) { $0 + $1.speed } / Double(chosen.count)
        return Wind(
            directionFrom: Geo.normalizeDegrees(atan2(-meanU, -meanV) * 180 / .pi),
            speed: meanSpeed,
            gust: chosen.compactMap(\.gust).max(),
            source: source,
            confidence: confidence
        )
    }
}

// MARK: - Nowcasting

/// A model series corrected by one fresh observation.
///
/// The guide's 0–6 hour rule (§6.7): the most useful thing a live station
/// reading can do is not replace the forecast but *nudge* it. Subtract the
/// model from the observation at the moment of the reading — in components —
/// and let that innovation decay exponentially with lead time, because a
/// station's disagreement with the model says a lot about the next hour and
/// nothing about tomorrow.
///
/// Pure arithmetic, no opinions about which station to trust — picking a
/// representative observation is the caller's problem, and the hard one.
public struct WindNowcast: Hashable, Sendable {

    /// Hours for the innovation to decay to 1/e. The guide suggests learning
    /// this per station and regime; three hours is its sensible middle.
    public var tauHours: Double

    public init(tauHours: Double = 3) {
        self.tauHours = tauHours
    }

    /// The timeline with the observation's disagreement blended in.
    ///
    /// Samples before the observation are left alone — the past is not
    /// improved by correcting it; the sample at the observation's own moment
    /// is corrected whole, so the series starts from what was actually
    /// measured. Gusts are left alone too: the innovation
    /// is about the mean, and stretching it over the gusts would be
    /// invention. When the model has nothing to say at the observation's
    /// moment there is no innovation to compute, and the timeline comes back
    /// untouched.
    public func corrected(_ timeline: WindTimeline, by observation: WindTimeline.Sample) -> WindTimeline {
        guard let modelled = timeline.wind(at: observation.time) else { return timeline }
        let innovationU = observation.u - modelled.u
        let innovationV = observation.v - modelled.v
        let corrected = timeline.samples.map { sample -> WindTimeline.Sample in
            let leadHours = sample.time.timeIntervalSince(observation.time) / 3600
            guard leadHours >= 0 else { return sample }
            let decay = exp(-leadHours / tauHours)
            var adjusted = sample
            adjusted.u += innovationU * decay
            adjusted.v += innovationV * decay
            return adjusted
        }
        return WindTimeline(samples: corrected)
    }
}
