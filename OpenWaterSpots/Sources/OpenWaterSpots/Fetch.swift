import Foundation

/// One GET, retried, for the small forecast calls.
///
/// Every one of these used to be a bare `try?` around `URLSession.data`,
/// which flattened a dropped connection, a 429 and a genuinely empty answer
/// into the same `nil` — and the screens above then reported that nil as a
/// fact about the weather. "No model wind for this point" was printed over
/// Block Island Sound, where Open-Meteo answers perfectly well; what had
/// actually happened was that one request out of eight fired at once had not
/// come back.
///
/// A television makes this worse than a phone does. It sits on a network
/// nobody is watching, wakes from sleep with the radio still coming up, and
/// the first request after a press is the one most likely to miss — with
/// nobody able to pull-to-refresh, because there is no pulling.
///
/// Cancellation is not failure and is never retried: it means the rider left.
enum Fetch {

    /// How long one attempt may hang. The system default is sixty seconds,
    /// and three of those held the conditions sheet on "Looking for public
    /// stations…" for three minutes over one stalled request.
    static let timeout: TimeInterval = 15

    static func data(_ url: URL, attempts: Int = 3) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for attempt in 0..<attempts {
            if Task.isCancelled { return nil }
            var retryAfter: TimeInterval?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if code == 200 { return data }
                if code == 429 {
                    // Rate limited. The free tier says so per minute and per
                    // hour, and a retry four hundred milliseconds later is
                    // the wrong shape for that: it honours `Retry-After`
                    // where one is given, and otherwise waits a real
                    // interval once rather than hammering three times.
                    retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init).map { min(max($0, 1), 10) } ?? 5
                }
                // A 4xx that is not a rate limit is our own malformed request
                // and will read the same way however many times it is asked.
                else if (400..<500).contains(code) { return nil }
            } catch is CancellationError {
                return nil
            } catch {
                if (error as? URLError)?.code == .cancelled { return nil }
            }
            // 0.4s, then 0.8s. Short enough that a rider reads it as the page
            // loading rather than as the page being broken.
            if attempt < attempts - 1 {
                let wait = retryAfter ?? Double(400 << attempt) / 1000
                try? await Task.sleep(for: .seconds(wait))
                if retryAfter != nil, attempt >= 1 { return nil }
            }
        }
        return nil
    }
}
