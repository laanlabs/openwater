import Foundation
import OpenWaterCore

/// Google DeepMind's WeatherNext 3, as a second opinion on the wind.
///
/// A generative model rather than a physics solver, run every six hours on a
/// 0.1° grid, and — the part that matters here — a genuine 64-member
/// ensemble whose spread arrives pre-reduced to percentiles. The median is
/// one more line on the model compare screen; p10 and p90 are a fan the
/// deterministic models cannot draw at all.
///
/// **The app never talks to Google's dataset.** The forecast lives in
/// BigQuery, which bills by the query and needs a credential, and a phone
/// holding either is a phone that can run up a bill. So a Cloud Run job in
/// `cloud/weathernext/` asks once per run, for every guide spot at once, and
/// leaves one small JSON per spot in a public bucket. This type reads that
/// file, which is why it is keyed by spot id rather than by coordinate: an
/// arbitrary point on the map has no file, and gets no WeatherNext line.
///
/// **No gusts.** WeatherNext publishes no gust variable, so this model's
/// `gusts` stay empty and the gust band is drawn from the others.
///
/// Licensing is recorded in docs/WEATHERNEXT.md; the attribution the terms
/// ask for is on the sources screen.
public enum WeatherNext {

    public static let bucket = "openwater-weathernext"
    public static let modelId = "weathernext"
    public static let label = "WeatherNext"

    /// One spot's published series, straight off the bucket: hourly, UTC,
    /// knots and degrees-from, as the publisher wrote them.
    public struct Series: Sendable {
        public let initTime: Date?
        public let times: [Date]
        public let p10: [Double?]
        public let p50: [Double?]
        public let p90: [Double?]
        public let directions: [Double?]

        /// The series laid onto another outlook's hour axis, so it can sit
        /// beside models that were asked for a different span. Hours the
        /// publisher did not cover read nil, which every consumer of
        /// `WindOutlook.Model` already treats as "this model stops here".
        public func aligned(to hours: [Date]) -> WindOutlook.Model {
            var slot: [Int: Int] = [:]
            for (index, time) in times.enumerated() {
                slot[Int(time.timeIntervalSince1970.rounded())] = index
            }
            func lay(_ values: [Double?]) -> [Double?] {
                hours.map { hour in
                    slot[Int(hour.timeIntervalSince1970.rounded())].flatMap { values[safe: $0] ?? nil }
                }
            }
            return WindOutlook.Model(
                id: WeatherNext.modelId, label: WeatherNext.label,
                speeds: lay(p50), gusts: [], directions: lay(directions),
                low: lay(p10), high: lay(p90))
        }
    }

    static func url(spotId: String) -> URL? {
        guard let id = spotId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://storage.googleapis.com/\(bucket)/spots/\(id).json")
    }

    /// The published series for a guide spot, or nil where there is none —
    /// a spot the publisher has not reached, or a bucket that is down. A
    /// quarter of an hour on disk, matching the bucket's own cache header:
    /// a new run lands twice a day and should show within minutes.
    public static func series(spotId: String) async -> Series? {
        guard let url = url(spotId: spotId),
              let served = await ForecastCache.serve(from: url, ttl: 900),
              let root = try? JSONSerialization.jsonObject(with: served.data) as? [String: Any],
              let stamps = root["times"] as? [Double]
        else { return nil }
        func column(_ key: String) -> [Double?] {
            (root[key] as? [Any])?.map { $0 as? Double } ?? []
        }
        let formatter = ISO8601DateFormatter()
        return Series(
            initTime: (root["init"] as? String).flatMap(formatter.date(from:)),
            times: stamps.map { Date(timeIntervalSince1970: $0) },
            p10: column("p10"), p50: column("p50"), p90: column("p90"),
            directions: column("dir"))
    }
}
