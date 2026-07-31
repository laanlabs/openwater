import Foundation

/// A speed category is a rule for extracting one headline number from a track.
///
/// The set is deliberately open: the standard community categories are built in,
/// but a rider can add "best average over 3 km" or "best 45 seconds" and the
/// engine handles it identically, recomputing from the stored track.
public enum SpeedCategory: Hashable, Sendable, Codable, Identifiable {

    /// Best average speed over a fixed duration.
    case time(seconds: TimeInterval)

    /// Average of the *n* best non-overlapping windows of a fixed duration.
    /// `n: 5, seconds: 10` is the core community ranking metric.
    case multiTime(count: Int, seconds: TimeInterval)

    /// Best average speed over a fixed distance, flying start.
    case distance(metres: Double)

    /// A 500 m run containing a turn that finishes within 50 m of its start.
    case alpha(metres: Double, proximity: Double)

    public var id: String {
        switch self {
        case .time(let s): "time-\(s)"
        case .multiTime(let n, let s): "multi-\(n)x\(s)"
        case .distance(let m): "dist-\(m)"
        case .alpha(let m, let p): "alpha-\(m)-\(p)"
        }
    }

    /// Short label for a metric tile.
    public var shortName: String {
        switch self {
        case .time(let s): Self.durationLabel(s)
        case .multiTime(let n, let s): "\(n) × \(Self.durationLabel(s))"
        case .distance(let m): Self.distanceLabel(m)
        case .alpha(let m, _): "Alpha \(Self.distanceLabel(m))"
        }
    }

    /// Full label with the rule spelled out, for the detail screen.
    public var displayName: String {
        switch self {
        case .time(let s): "Best \(Self.durationLabel(s))"
        case .multiTime(let n, let s): "Average of best \(n) × \(Self.durationLabel(s))"
        case .distance(let m): "Fastest \(Self.distanceLabel(m))"
        case .alpha(let m, let p):
            "Alpha \(Self.distanceLabel(m)) — turn, finish within \(Int(p)) m of the start"
        }
    }

    /// One-line explanation surfaced behind an info tap, because half of these
    /// rules are non-obvious the first time you meet them.
    public var explanation: String {
        switch self {
        case .time(let s) where s <= 2:
            "Your absolute peak — the fastest \(Self.durationLabel(s)) anywhere in the session. Exciting, but the most sensitive to GPS noise."
        case .time(let s):
            "The fastest you held an average for \(Self.durationLabel(s)) without a break."
        case .multiTime(let n, let s):
            "Your \(n) best separate \(Self.durationLabel(s)) bursts, averaged. Rewards repeatable speed over a single lucky run, which is why it is the standard ranking metric."
        case .distance(let m):
            "The quickest you covered \(Self.distanceLabel(m)) of track, starting from wherever you were already up to speed."
        case .alpha(let m, let p):
            "A \(Self.distanceLabel(m)) run that includes a turn and finishes within \(Int(p)) m of where it started. It measures speed you can actually use in a confined spot, since you have to come back."
        }
    }

    // MARK: - Standard sets

    /// The community-standard categories, in the order riders expect them.
    public static let standard: [SpeedCategory] = [
        .time(seconds: 2),
        .multiTime(count: 5, seconds: 10),
        .time(seconds: 10),
        .distance(metres: 100),
        .distance(metres: 250),
        .distance(metres: 500),
        .alpha(metres: 500, proximity: 50),
        .distance(metres: 1852),
        .time(seconds: 1800),
        .time(seconds: 3600),
    ]

    /// Extra windows that suit long-distance winging and downwind runs, where
    /// "max speed over X km" is the question people actually ask.
    public static let distanceOriented: [SpeedCategory] = [
        .distance(metres: 1000),
        .distance(metres: 2000),
        .distance(metres: 5000),
        .distance(metres: 10000),
    ]

    public static let all: [SpeedCategory] = standard + distanceOriented

    /// Categories worth computing live on a watch — anything longer is cheap to
    /// leave for the post-session pass.
    public static let live: [SpeedCategory] = [
        .time(seconds: 2),
        .time(seconds: 10),
        .multiTime(count: 5, seconds: 10),
        .distance(metres: 100),
        .distance(metres: 500),
        .alpha(metres: 500, proximity: 50),
    ]

    // MARK: - Labels

    static func durationLabel(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s)) s" }
        if s < 3600 {
            let m = s / 60
            return m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)
        }
        let h = s / 3600
        return h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
    }

    static func distanceLabel(_ m: Double) -> String {
        if m == 1852 { return "NM" }
        if m < 1000 { return "\(Int(m)) m" }
        let km = m / 1000
        return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
    }
}

/// The outcome of evaluating one category against one track.
public struct SpeedResult: Hashable, Sendable, Codable, Identifiable {

    public let category: SpeedCategory

    /// Mean speed over the qualifying window, m/s.
    public let speed: Double

    /// Elapsed-time bounds of the window, seconds from track start.
    /// For a multi-window category these span the first to the last segment.
    public let startElapsed: TimeInterval
    public let endElapsed: TimeInterval

    /// Distance covered by the window, metres.
    public let distance: Double

    /// The individual segments — one for a simple category, several for `5 × 10 s`.
    public let segments: [Segment]

    /// Whether the track actually satisfied the category's rule.
    public let isValid: Bool

    /// Why not, when `isValid` is false.
    public let invalidReason: InvalidReason?

    /// 0–1. Blends GPS quality inside the window with the speed source, so the
    /// UI can grey out a number rather than silently presenting a fantasy.
    public let confidence: Double

    public var id: String { category.id }

    public var duration: TimeInterval { endElapsed - startElapsed }

    public struct Segment: Hashable, Sendable, Codable {
        public let startElapsed: TimeInterval
        public let endElapsed: TimeInterval
        public let distance: Double
        public let speed: Double

        public init(startElapsed: TimeInterval, endElapsed: TimeInterval, distance: Double, speed: Double) {
            self.startElapsed = startElapsed
            self.endElapsed = endElapsed
            self.distance = distance
            self.speed = speed
        }

        public var duration: TimeInterval { endElapsed - startElapsed }
    }

    public enum InvalidReason: String, Sendable, Codable {
        case trackTooShort
        case notEnoughDistance
        case notEnoughDuration
        case notEnoughSegments
        case noQualifyingTurn
        case didNotReturnToStart

        public var displayName: String {
            switch self {
            case .trackTooShort: "Track too short"
            case .notEnoughDistance: "Not enough distance covered"
            case .notEnoughDuration: "Session shorter than the window"
            case .notEnoughSegments: "Not enough separate runs"
            case .noQualifyingTurn: "No turn inside the run"
            case .didNotReturnToStart: "Never finished near a start point"
            }
        }
    }

    public init(
        category: SpeedCategory,
        speed: Double,
        startElapsed: TimeInterval,
        endElapsed: TimeInterval,
        distance: Double,
        segments: [Segment],
        isValid: Bool,
        invalidReason: InvalidReason? = nil,
        confidence: Double
    ) {
        self.category = category
        self.speed = speed
        self.startElapsed = startElapsed
        self.endElapsed = endElapsed
        self.distance = distance
        self.segments = segments
        self.isValid = isValid
        self.invalidReason = invalidReason
        self.confidence = confidence
    }

    /// An empty, failed result — used when the track cannot satisfy the rule.
    public static func unavailable(_ category: SpeedCategory, reason: InvalidReason) -> SpeedResult {
        SpeedResult(
            category: category,
            speed: 0,
            startElapsed: 0,
            endElapsed: 0,
            distance: 0,
            segments: [],
            isValid: false,
            invalidReason: reason,
            confidence: 0
        )
    }
}
