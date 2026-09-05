import CoreGraphics
import Foundation
import ImageIO
import OpenWaterCore

/// The model's own radar picture — what weather.gov calls "future radar".
///
/// NOAA's HRRR runs every hour at 3 km over the continental United States and
/// writes, among everything else, *simulated reflectivity*: what a radar would
/// see if the model's rain were real. That is the field behind every "future
/// radar" a rider has seen on a weather site, and it is a model — the same
/// caveat as the wind wash, drawn in radar's own colours because radar is the
/// language the room already reads.
///
/// **Where it comes from.** NOAA publishes the raw fields as GRIB2, which an
/// Apple TV has no business decoding. Iowa State's Mesonet renders each
/// forecast step to a georeferenced PNG the moment a run lands — every
/// fifteen minutes out to eighteen hours, hourly to forty-eight — with a
/// world file beside it saying where the pixels sit and a JSON saying which
/// run and which minute. This reads those three files and nothing else.
///
/// **Why not tiles.** The pictures are whole-CONUS images in plain latitude
/// and longitude (EPSG:4326), one per step. The radar screens compose slippy
/// tiles; this hands them a single image and its corners instead, and the
/// screen places it — see the television's `RadarImageMap`, which draws it
/// in latitude strips so the equirectangular picture lands correctly on a
/// Mercator map.
///
/// **Coverage.** Roughly 126°W to 65°W, 23°N to 50°N. Outside that box the
/// pictures are black, and the caller should fall back to the model wash.
public enum HRRRReflectivity: Sendable {

    private static let base = "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/"

    /// One forecast step: which run, how far ahead, and where its pixels sit.
    public struct Frame: Hashable, Identifiable, Sendable {
        /// Minutes past the run's start.
        public let minutesAhead: Int
        /// When the run began, UTC.
        public let runAt: Date
        /// The instant this picture is a forecast *for*.
        public let validAt: Date
        /// The world file: degrees per pixel and the top-left corner.
        public let degreesPerPixel: Double
        public let west: Double
        public let north: Double

        /// The run is in the id, so a new run is a new set of frames even
        /// though the file names never change.
        public var id: String { "hrrr-\(Int(runAt.timeIntervalSince1970))-\(minutesAhead)" }

        public var imageURL: URL {
            URL(string: HRRRReflectivity.base + HRRRReflectivity.name(minutesAhead) + ".png")!
        }

        /// The picture's rectangle on the ground, given its pixel size.
        public func bounds(width: Int, height: Int) -> (west: Double, north: Double,
                                                        east: Double, south: Double) {
            (west, north,
             west + Double(width) * degreesPerPixel,
             north - Double(height) * degreesPerPixel)
        }
    }

    /// The box the pictures cover, as published on 2026-09-05: 3050×1340
    /// pixels of 0.02° from 126°W 50°N. Checked against the world file each
    /// time frames are fetched; this constant is only for `covers`, which
    /// has to answer before anything has been fetched.
    public static let coverage = (west: -126.0, north: 50.0, east: -65.0, south: 23.2)

    public static func covers(_ point: Geo.Coordinate) -> Bool {
        point.longitude >= coverage.west && point.longitude <= coverage.east
            && point.latitude >= coverage.south && point.latitude <= coverage.north
    }

    /// The frames nearest these offsets from *now*, in order — only the ones
    /// the server has and that describe the same run.
    ///
    /// From now, not from the run. A run takes an hour and a half to be
    /// rendered and posted, so at five o'clock the newest set on the server
    /// is the three o'clock run, and its first frames are the past: asking
    /// for "minute 0" and captioning it "Now" showed a rider a picture two
    /// hours stale under the word that means the opposite. So the run's
    /// start is read first, each wanted instant is turned into that run's
    /// nearest minute — quarter hours inside eighteen, whole hours beyond —
    /// and the sequence begins at the frame that is actually now.
    public static func frames(aheadOfNow offsets: [TimeInterval], now: Date = Date()) async -> [Frame] {
        guard let world = await worldFile(),
              let opening = await frame(minutesAhead: 0, world: world)
        else { return [] }
        let run = opening.runAt
        var minutes: [Int] = []
        for offset in offsets {
            let sinceRun = now.addingTimeInterval(offset).timeIntervalSince(run) / 60
            let step = sinceRun <= 1080 ? 15.0 : 60.0
            let minute = Int((sinceRun / step).rounded() * step)
            let clamped = min(max(minute, 0), 2880)
            if !minutes.contains(clamped) { minutes.append(clamped) }
        }

        var found: [Frame] = []
        await withTaskGroup(of: Frame?.self) { group in
            for minute in minutes {
                group.addTask { await frame(minutesAhead: minute, world: world) }
            }
            for await frame in group {
                if let frame { found.append(frame) }
            }
        }
        // One run only. The server rewrites the files as a new run lands,
        // and a set caught mid-rewrite would splice two runs together; the
        // run the opening frame named wins and the stragglers are dropped.
        return found.filter { $0.runAt == run }.sorted { $0.minutesAhead < $1.minutesAhead }
    }

    /// The picture for a frame, as the server draws it: opaque RGB, echoes in
    /// the weather service's reflectivity colours on a black ground. Nil when
    /// the server has nothing, or something that is not a picture. Keying the
    /// ground out and smoothing the 2 km pixels is the drawer's business — it
    /// knows the zoom, and this does not.
    public static func image(for frame: Frame) async -> CGImage? {
        // Ten minutes: a run lands hourly and the files are rewritten in
        // place, so a cache that outlived the run would show the last hour's
        // forecast under this hour's caption.
        guard let data = await ForecastCache.data(from: frame.imageURL, ttl: 600),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Plumbing

    private struct World: Sendable {
        let degreesPerPixel: Double
        let west: Double
        let north: Double
    }

    /// `refd_0060`, zero-padded to four digits the way the server names them.
    static func name(_ minutes: Int) -> String {
        String(format: "refd_%04d", minutes)
    }

    /// An ESRI world file: six lines — x pixel size, two rotations, negative
    /// y pixel size, then the x and y of the top-left pixel.
    private static func worldFile() async -> World? {
        guard let url = URL(string: base + name(0) + ".wld"),
              let data = await ForecastCache.data(from: url, ttl: 3600),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let numbers = text.split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 6, numbers[0] > 0 else { return nil }
        return World(degreesPerPixel: numbers[0], west: numbers[4], north: numbers[5])
    }

    private static let stamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func frame(minutesAhead: Int, world: World) async -> Frame? {
        guard let url = URL(string: base + name(minutesAhead) + ".json"),
              let data = await ForecastCache.data(from: url, ttl: 300),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runText = root["model_init_utc"] as? String,
              let validText = root["model_forecast_utc"] as? String,
              let runAt = stamps.date(from: runText),
              let validAt = stamps.date(from: validText)
        else { return nil }
        return Frame(minutesAhead: minutesAhead, runAt: runAt, validAt: validAt,
                     degreesPerPixel: world.degreesPerPixel, west: world.west, north: world.north)
    }
}
