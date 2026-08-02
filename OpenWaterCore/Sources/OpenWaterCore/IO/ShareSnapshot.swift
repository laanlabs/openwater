import Foundation
#if canImport(Security)
import Security
#endif

/// A session reduced to what a web page needs to draw it.
///
/// Deliberately *not* the `.openwater` archive. That format is lossless and
/// megabytes; this one has to survive being uploaded over a phone connection on
/// a beach and downloaded by whoever taps the link. It carries the track at a
/// resolution a map can actually render, the headline numbers, and nothing else.
///
/// It is also the only thing openWater ever sends off the device, so what is in
/// it matters. Notes, gear, heart rate, device identifiers and the raw fixes are
/// all excluded — not because they would not fit, but because a rider sharing a
/// speed run is not consenting to publish the rest.
public struct ShareSnapshot: Sendable, Codable {

    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date

    public var title: String
    public var sport: String
    public var sportSymbol: String
    public var date: Date

    /// Headline figures, pre-formatted in metres and m/s so the web page does
    /// not have to reimplement the unit conversions and risk disagreeing with
    /// the app about a number.
    public var distance: Double
    public var duration: TimeInterval
    public var movingTime: TimeInterval
    public var maxSpeed: Double
    public var averageMovingSpeed: Double

    /// Named speed categories that were actually achieved, in display order.
    public var categories: [Category]

    /// Time on foil as a fraction, when the sport has one.
    public var foilingFraction: Double?
    public var flightCount: Int?
    public var runCount: Int

    /// The track, downsampled. `[longitude, latitude, speed]` per point —
    /// longitude first, matching GeoJSON, so the web page cannot get it the
    /// wrong way round and draw the session in the Indian Ocean.
    public var points: [[Double]]

    /// Speed at the top of the colour ramp, so the page shades the track the
    /// same way the app does.
    ///
    /// Kept for links shared before `speedFloor` existed: the page falls back
    /// to the old `0.35 × ceiling … ceiling` range when the floor is absent, so
    /// an old snapshot still renders rather than coming out black.
    public var speedCeiling: Double

    /// Speed at the bottom of the colour ramp.
    ///
    /// Optional because it was added after the format shipped, and shared
    /// snapshots are written once and never rewritten — an old one on Firebase
    /// will never have this key. See `SpeedScale` for why the ramp is anchored
    /// to the session's own spread rather than to its peak.
    public var speedFloor: Double?

    public struct Category: Sendable, Codable {
        public var name: String
        public var speed: Double
    }

    public init(
        version: Int = ShareSnapshot.currentVersion,
        createdAt: Date = Date(),
        title: String,
        sport: String,
        sportSymbol: String,
        date: Date,
        distance: Double,
        duration: TimeInterval,
        movingTime: TimeInterval,
        maxSpeed: Double,
        averageMovingSpeed: Double,
        categories: [Category],
        foilingFraction: Double?,
        flightCount: Int?,
        runCount: Int,
        points: [[Double]],
        speedCeiling: Double,
        speedFloor: Double? = nil
    ) {
        self.version = version
        self.createdAt = createdAt
        self.title = title
        self.sport = sport
        self.sportSymbol = sportSymbol
        self.date = date
        self.distance = distance
        self.duration = duration
        self.movingTime = movingTime
        self.maxSpeed = maxSpeed
        self.averageMovingSpeed = averageMovingSpeed
        self.categories = categories
        self.foilingFraction = foilingFraction
        self.flightCount = flightCount
        self.runCount = runCount
        self.points = points
        self.speedCeiling = speedCeiling
        self.speedFloor = speedFloor
    }

    // MARK: - Building

    /// Build a snapshot from a session.
    ///
    /// - Parameters:
    ///   - privacy: applied *before* anything else. Endpoint trimming is the
    ///     whole point here — the first and last coordinates of a track are
    ///     somebody's launch, and a public link is exactly the case it exists
    ///     for.
    ///   - maximumPoints: the track is reduced to at most this many. A three-
    ///     hour session is ten thousand fixes; a map on a phone browser cannot
    ///     usefully draw more than about a thousand.
    public static func make(
        from session: Session,
        privacy: PrivacySettings = .sharing,
        maximumPoints: Int = 1200
    ) -> ShareSnapshot {
        let prepared = privacy.apply(to: session)
        let track = prepared.track
        let summary = prepared.summary

        let points = downsample(track: track, to: maximumPoints)
        // Fixed, not per session — see `SpeedScale`. Still sent rather than
        // hard-coded in the page, so a link drawn today keeps the ramp it was
        // shared with if the app's ever changes.
        let scale = SpeedScale.standard

        return ShareSnapshot(
            title: prepared.displayTitle,
            sport: prepared.sport.displayName,
            sportSymbol: prepared.sport.symbolName,
            date: prepared.startDate,
            distance: summary?.distance ?? track.totalDistance,
            duration: summary?.duration ?? track.duration,
            movingTime: summary?.movingTime ?? 0,
            maxSpeed: summary?.maxSpeed ?? 0,
            averageMovingSpeed: summary?.averageMovingSpeed ?? 0,
            categories: (summary?.speedResults ?? [])
                .filter(\.isValid)
                .map { Category(name: $0.category.shortName, speed: $0.speed) },
            foilingFraction: prepared.sport.isFoiling ? summary?.foil.foilingFraction : nil,
            flightCount: prepared.sport.isFoiling ? summary?.foil.flightCount : nil,
            runCount: summary?.runs.count ?? 0,
            points: points,
            // The same scale the app draws with, so a link looks like the
            // session it came from rather than like a different recording.
            speedCeiling: scale.upper,
            speedFloor: scale.lower
        )
    }

    /// Reduce the track, keeping the fast points.
    ///
    /// Taking every nth fix would clip the peaks, and the peaks are what a
    /// speed-coloured track is *for* — a shared map whose fastest run has been
    /// averaged away is worse than no map. Each bucket therefore contributes its
    /// fastest sample rather than its first.
    static func downsample(track: Track, to maximum: Int) -> [[Double]] {
        guard track.count > 0 else { return [] }
        guard track.count > maximum else {
            return track.points.indices.map { index in
                [
                    round(track.points[index].longitude * 1e5) / 1e5,
                    round(track.points[index].latitude * 1e5) / 1e5,
                    round(track.speed[index] * 10) / 10,
                ]
            }
        }

        let stride = Int(ceil(Double(track.count) / Double(maximum)))
        var result: [[Double]] = []
        result.reserveCapacity(maximum + 1)

        var i = 0
        while i < track.count {
            let end = min(i + stride, track.count)
            var fastest = i
            for k in i..<end where track.speed[k] > track.speed[fastest] { fastest = k }
            result.append([
                // Five decimal places is about a metre — far finer than a map
                // can show, and it roughly halves the payload against full
                // double precision.
                round(track.points[fastest].longitude * 1e5) / 1e5,
                round(track.points[fastest].latitude * 1e5) / 1e5,
                round(track.speed[fastest] * 10) / 10,
            ])
            i = end
        }
        return result
    }

    // MARK: - Coding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ShareSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShareSnapshot.self, from: data)
    }

    /// A short, unguessable code for the share URL.
    ///
    /// Twenty-two characters from a 64-symbol alphabet is about 132 bits, which
    /// is the actual access control here: the file is world-readable to anyone
    /// holding the link, so the link has to be impossible to stumble onto.
    public static func makeCode() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var bytes = [UInt8](repeating: 0, count: 22)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
