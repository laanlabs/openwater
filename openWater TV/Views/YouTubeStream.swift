import Foundation
import os

/// Resolving a YouTube live cam to something `AVPlayer` can open.
///
/// **Off unless a rider turns it on.** See `SettingsScreen`: this is opt-in,
/// and the switch says plainly what it is. Nothing calls this while that
/// default is false.
///
/// **What it does.** YouTube's own apps fetch a video through an internal
/// endpoint — InnerTube — rather than the public Data API, which returns
/// metadata and never a playable URL. A *live* stream comes back from that
/// endpoint with an HLS manifest, which is exactly the shape `AVPlayer` wants
/// and, unlike the on-demand formats, is not ciphered. Every camera in the
/// guide is a live stream, so the limit costs nothing here — and the whole
/// ciphered-URL problem, which is what makes a general YouTube client hard,
/// is never entered.
///
/// **Why there is a list of clients.** Which client identity you present
/// changes the answer, and which ones work changes over time as YouTube
/// tightens things: one may return HLS, the next `LOGIN_REQUIRED`, the next
/// only on-demand formats. So this tries several in order and takes the first
/// that yields a manifest, rather than betting the feature on one that was
/// working the week it was written. `lastFailure` keeps why the last attempt
/// came back empty, because "this camera went off air" and "the shape we ask
/// in stopped working" need very different responses and look identical from
/// the sofa.
///
/// **What it is not.** No code from any existing client is used here — the
/// obvious one, SmartTubeIOS, is GPL-3.0 and openWater is MIT, so vendoring it
/// would relicense this app. This is written from the request shape alone.
///
/// **The honest warning.** Reaching a private endpoint by presenting a client
/// identifier that is not ours is against YouTube's terms, and it is brittle
/// by construction: the plain watch page used to carry `hlsManifestUrl` and no
/// longer does, which is what this replaces. Both facts are on the switch.
@MainActor
enum YouTubeStream {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater",
                                       category: "YouTube")

    /// One identity to ask as.
    ///
    /// The four strings are kept together rather than sprinkled through the
    /// request because when a client stops working these are the whole of
    /// what has to change.
    private struct Client {
        let name: String
        let version: String
        /// The `X-YouTube-Client-Name` number that goes with `name`.
        let number: String
        let userAgent: String
        /// Whatever else this client's context is expected to carry.
        let device: [String: String]
    }

    /// Tried in this order. The television client first — it is the one an
    /// Apple TV most honestly resembles and the one most likely to be handed
    /// a plain HLS live manifest — then the mobile clients, then the web,
    /// which also answers live streams with HLS and needs no pretence about
    /// hardware at all.
    private static let clients: [Client] = [
        Client(name: "TVHTML5", version: "7.20250312.16.00", number: "7",
               userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
               device: ["deviceMake": "Apple", "deviceModel": "AppleTV",
                        "osName": "tvOS", "osVersion": "18.3"]),
        Client(name: "IOS", version: "20.11.6", number: "5",
               userAgent: "com.google.ios.youtube/20.11.6 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X)",
               device: ["deviceMake": "Apple", "deviceModel": "iPhone16,2",
                        "osName": "iPhone", "osVersion": "18.3.2.22D82"]),
        Client(name: "ANDROID", version: "20.10.38", number: "3",
               userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
               device: ["osName": "Android", "osVersion": "14",
                        "androidSdkVersion": "34"]),
        Client(name: "WEB", version: "2.20250312.04.00", number: "1",
               userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
               device: [:]),
    ]

    /// Why the last resolve came back with nothing, in a form short enough to
    /// print on the hand-off screen. Nil once anything succeeds.
    ///
    /// On screen rather than only in the log because the person who can see
    /// this failing is holding a remote, not a console — and the difference
    /// between `LOGIN_REQUIRED` (YouTube now wants attestation, and this
    /// feature is finished) and `no manifest` (this cam is not live) decides
    /// whether the switch is worth keeping at all.
    private(set) static var lastFailure: String?

    private struct Cached {
        let url: URL
        let at: Date
    }

    private static let ttl: TimeInterval = 20 * 60
    /// Main-actor isolated rather than locked: every caller is a view acting
    /// on a button press, and a lock held across an `await` is unavailable in
    /// an async context anyway.
    private static var cache: [String: Cached] = [:]

    /// The HLS manifest for a live video, or nil — which is a complete
    /// answer. Every call site falls back to the QR hand-off, which works
    /// whatever YouTube does.
    static func manifest(for videoID: String) async -> URL? {
        if let hit = cache[videoID], Date().timeIntervalSince(hit.at) < ttl { return hit.url }

        var reasons: [String] = []
        for client in clients {
            switch await ask(client, for: videoID) {
            case .success(let url):
                logger.notice("""
                    hls via \(client.name, privacy: .public) \
                    for \(videoID, privacy: .public)
                    """)
                lastFailure = nil
                cache[videoID] = Cached(url: url, at: Date())
                return url
            case .failure(let why):
                logger.notice("""
                    \(client.name, privacy: .public) gave no hls \
                    for \(videoID, privacy: .public): \(why, privacy: .public)
                    """)
                reasons.append("\(client.name): \(why)")
            }
        }
        lastFailure = reasons.joined(separator: " · ")
        return nil
    }

    private enum Answer {
        case success(URL)
        case failure(String)
    }

    private static func ask(_ client: Client, for videoID: String) async -> Answer {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player") else {
            return .failure("bad endpoint")
        }
        var context: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US",
        ]
        for (key, value) in client.device { context[key] = value }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.number, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": context],
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure("no answer")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { return .failure("http \(code)") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("unreadable")
        }

        let playability = root["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "?"
        let streaming = root["streamingData"] as? [String: Any]

        if let manifest = streaming?["hlsManifestUrl"] as? String,
           let url = URL(string: manifest) {
            return .success(url)
        }
        // Named precisely. "OK but no manifest" means this video is not a
        // live stream — a real and permanent answer about this camera.
        // Anything else is a statement about our access, not about the cam.
        if status != "OK" {
            let reason = playability?["reason"] as? String
            return .failure(reason.map { "\(status) (\($0))" } ?? status)
        }
        return .failure(streaming == nil ? "no streamingData" : "not live")
    }
}
