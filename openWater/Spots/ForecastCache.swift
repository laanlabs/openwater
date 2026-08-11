import CryptoKit
import Foundation

/// A short disk memory for forecast responses.
///
/// The conditions sheet asks Open-Meteo about ten questions every time it
/// opens, and a rider flicking between two spots re-asks all ten about
/// both. A forecast model that runs once an hour has nothing new to say
/// three minutes later, so within each answer's time-to-live it is reused
/// straight from disk and the network is not touched.
///
/// The same files are the offline story: when a fetch fails, an answer up
/// to three hours old is served instead of a blank. Forecasts age gently —
/// this morning's model run is not less honest than "no data", it is just
/// slightly older, and the cards it feeds are already labelled as models.
///
/// Observations are deliberately *not* cached here. A station reading's
/// whole value is being minutes old; serving last hour's anemometer as
/// live would be exactly the "stale current conditions" failure the guide
/// warns about. The NWS, tide and buoy fetchers keep their own untouched
/// network paths.
enum ForecastCache {

    /// How old a cached answer may be and still beat a blank screen.
    private static let staleLimit: TimeInterval = 3 * 3600

    private static var directory: URL {
        URL.cachesDirectory.appending(path: "forecasts", directoryHint: .isDirectory)
    }

    /// One file per distinct request, named by the URL's digest — the query
    /// string *is* the identity, coordinates and parameters both.
    private static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appending(path: "\(name).json")
    }

    /// A response body plus the honesty about where it came from.
    struct Served {
        let data: Data
        /// Only set on the fallback path: the network failed and this is
        /// the last good answer, this many seconds old. `nil` means fresh —
        /// straight from the network, or from disk well inside its
        /// time-to-live, which is the same thing to the rider.
        let staleAge: TimeInterval?
    }

    /// The response body: from disk while fresh, from the network when not,
    /// from disk again — older, and saying so — when the network fails.
    static func serve(from url: URL, ttl: TimeInterval) async -> Served? {
        let path = file(for: url)
        if let age = age(of: path), age < ttl,
           let cached = try? Data(contentsOf: path) {
            return Served(data: cached, staleAge: nil)
        }
        if let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: path)
            return Served(data: data, staleAge: nil)
        }
        if let age = age(of: path), age < staleLimit,
           let cached = try? Data(contentsOf: path) {
            return Served(data: cached, staleAge: age)
        }
        return nil
    }

    /// `serve` for the callers whose cards have nowhere to put an age.
    static func data(from url: URL, ttl: TimeInterval) async -> Data? {
        await serve(from: url, ttl: ttl)?.data
    }

    private static func age(of path: URL) -> TimeInterval? {
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }
}
