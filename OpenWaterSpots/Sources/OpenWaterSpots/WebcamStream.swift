import Foundation
import os

/// Finding the video a public webcam page is showing you.
///
/// Most cameras in the guide are "web pages" only in the sense that a browser
/// is how their operator expects you to arrive. Underneath, the page hands its
/// own player ordinary URLs — an HLS playlist, or a handful of MP4 clips — and
/// an Apple TV can play those. All that is missing is the browser that would
/// normally do the reading, so this does the reading.
///
/// Shared by the phone and the television: both read the same page for
/// the same stream. **Not the YouTube case.** Nothing here presents itself as somebody else's
/// client or reaches a private endpoint. It fetches the same public page a
/// viewer would and takes the media URLs that page publishes to its own
/// player — the same thing the guide already does when it harvests a camera's
/// `stillUrl`. So it is on by default and has no switch.
///
/// **Everything, not the first thing.** The readers used to stop at the first
/// hit. They now pool their results, because a page very often carries more
/// than one camera — Montauk Point Lighthouse publishes five angles, an
/// EarthCam location page lists every camera on it — and the player puts
/// arrows on that list. First-wins threw four fifths of Montauk away.
///
/// **The rules are shapes, not sites.** An earlier pass keyed two readers to
/// specific pages: one to EarthCam's brand, one to the literal variable name
/// `clipUrls`. Both are now written as the shape underneath — a media URL
/// split across two JSON keys, and a script array of media filenames — so the
/// next operator doing the same thing under a different name is covered
/// without another reader.
@MainActor
public enum WebcamStream {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater",
                                       category: "Webcam")

    /// One thing to play, and what to call it.
    public struct Stream: Identifiable, Hashable, Sendable {
        public let url: URL
        /// Derived from the URL — "northside.mp4" is Northside. Operators name
        /// these after what they point at far more often than not, and a real
        /// name beats "Camera 2" every time.
        public let label: String
        /// A finite recording rather than a live stream. It has to be looped
        /// or the picture stops and reads as a broken camera.
        public let isClip: Bool
        public var id: String { url.absoluteString }
    }

    private struct Cached {
        let streams: [Stream]
        let at: Date
    }

    /// Short, because these carry signed tokens that expire — a stale
    /// playlist is a black screen, and re-reading a page costs one request.
    private static let ttl: TimeInterval = 15 * 60
    private static var cache: [URL: Cached] = [:]

    /// The one browser-shaped thing here: some operators serve something
    /// different to a client that does not look like a browser, and the point
    /// is to read the page a viewer is shown.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// How many split-URL candidates are worth probing. A location page can
    /// list a dozen cameras and several are usually off air; this bounds one
    /// button press to a handful of small requests.
    private static let probeLimit = 8

    public static func find(at page: URL) async -> [Stream] {
        if let hit = cache[page], Date().timeIntervalSince(hit.at) < ttl { return hit.streams }
        // A link that already *is* the video needs no reading. Palmetto
        // Dunes lists its cameras as `.../playlist.m3u8` outright, and
        // fetching that as a page found only the chunklist inside it — a
        // stream one level too deep, and one the operator can rename.
        if let direct = directMedia(page) { return [direct] }
        let found = await harvest(page, depth: 0)
        cache[page] = Cached(streams: found, at: Date())
        logger.notice("""
            \(found.count, privacy: .public) stream(s) at \
            \(page.absoluteString, privacy: .public)
            """)
        return found
    }

    /// One page's worth, plus one level of whatever it embeds.
    ///
    /// The recursion is the single most valuable generic rule here: a great
    /// many operator pages are a thin wrapper around a player hosted
    /// somewhere else, and stopping at the wrapper finds nothing at all.
    /// Depth one only — two would start crawling the open web from a button
    /// press.
    private static func harvest(_ page: URL, depth: Int) async -> [Stream] {
        guard let (raw, base) = await load(page) else { return [] }

        // Unescaped once, up front, and every reader sees that.
        //
        // This is worth more than any single reader. A great many pages write
        // their media URL inside JavaScript, where the slashes are escaped and
        // sometimes the hyphens too — measured on the guide's own cameras,
        // njbeachcams writes `...\/index.m3u8` and Angelcam writes
        // `e1-na8.angelcam.com`. Both were invisible, because a pattern
        // that matches a URL cannot contain a backslash and still be a URL.
        // Unescaping first found a stream on both, and neither needed a rule
        // of its own.
        let html = unescape(raw)

        var pooled: [Stream] = []
        pooled += await splitURLs(in: html)
        pooled += await hostedStreams(in: html)
        pooled += read(html, base: base)

        if pooled.isEmpty, depth == 0 {
            // The frames the page draws, and the ones a player SDK would
            // draw for it — see `embeddedPlayers`.
            for frame in (iframes(in: html, base: base) + embeddedPlayers(in: html)).prefix(3) {
                let inner = await harvest(frame, depth: 1)
                if !inner.isEmpty { pooled += inner; break }
            }
        }

        // Live before recorded, then de-duplicated by URL with the first
        // label kept — the readers overlap on purpose and the earlier ones
        // are the better-informed.
        var seen = Set<URL>()
        return pooled
            .filter { seen.insert($0.url).inserted }
            .sorted { !$0.isClip && $1.isClip }
    }

    /// Every reader that needs nothing but the page — the split-URL reader
    /// probes the network and is called beside this. Internal so a page can
    /// be handed in from a test as text, which is how a new shape gets
    /// pinned before it is trusted: the fixture is the operator's page as it
    /// was the day the rule was written.
    static func read(_ html: String, base: URL) -> [Stream] {
        var pooled: [Stream] = []
        pooled += playlists(in: html)
        pooled += relativeMedia(in: html, base: base)
        pooled += metaDeclared(in: html, base: base)
        pooled += videoElements(in: html, base: base)
        pooled += mediaArrays(in: html, base: base)
        return pooled
    }

    /// `unescape`, for tests that hand in a raw page the way `harvest` gets one.
    static func prepared(_ raw: String) -> String { unescape(raw) }

    /// The link itself, when it is a playlist or a clip rather than a page.
    static func directMedia(_ url: URL) -> Stream? {
        let ext = url.pathExtension.lowercased()
        guard ["m3u8", "mp4", "m4v", "mov"].contains(ext) else { return nil }
        return Stream(url: url, label: name(from: url, index: 0), isClip: ext != "m3u8")
    }

    private static func load(_ page: URL) async -> (html: String, base: URL)? {
        var request = URLRequest(url: page)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        // Where the page actually ended up, so relative names resolve against
        // the right directory after any redirect.
        return (html, response.url ?? page)
    }

    // MARK: The readers

    /// A media URL split across two JSON keys.
    ///
    /// EarthCam's shape, written as the shape: some key ending in `domain`
    /// holds a host, some key ending in `path` or `streampath` holds the rest,
    /// and concatenated they are a signed playlist. No single regex for a
    /// whole URL can find one of these, which is why it needs a rule of its
    /// own rather than falling to `playlists` below.
    ///
    /// Probed, because a location page lists cameras that are off air —
    /// measured on EarthCam's Times Square page, three of eleven answered
    /// 404. Every one that answers is kept, which is what gives the player
    /// its arrows.
    private static func splitURLs(in html: String) async -> [Stream] {
        let hosts = keyed(#""([a-z0-9_]*domain)"\s*:\s*"(https?:[^"]+)""#, in: html)
        let paths = keyed(#""([a-z0-9_]*(?:stream)?path)"\s*:\s*"(\\?/[^"]+)""#, in: html)
        guard !hosts.isEmpty, !paths.isEmpty else { return [] }

        var candidates: [URL] = []
        for path in paths where path.value.contains(".m3u8") {
            // Paired by key family, then by proximity — and both halves of
            // that were learned the hard way on EarthCam's Times Square page.
            //
            // Pairing the lists positionally assumed they alternate one for
            // one. They do not: each camera carries an rtmp `streamingdomain`
            // beside its `html5_streamingdomain`, so the lists drift and glue
            // one camera's host to another's path.
            //
            // Pairing by nearest preceding host alone is worse, because the
            // nearest one is often a bare `"domain":"www.earthcam.com"` — the
            // site, not the video CDN — which yields a confident 404. The key
            // prefix is what actually says these two belong together:
            // `html5_streampath` goes with `html5_streamingdomain`, and only
            // failing that with whatever came last.
            let sameFamily = hosts.last { $0.at < path.at && $0.family == path.family }
            // The fallback is deliberately narrow. Measured on EarthCam's
            // Times Square page, the hosts are eleven `html5_streamingdomain`
            // — the video CDN — and eleven `imagedomain`, which are picture
            // servers and no use here; the paths include `livepath`,
            // `android_livepath` and `livestreamingpath` beside the
            // `html5_streampath` we want. "Nearest preceding host of any
            // kind" cheerfully welded image hosts onto stream paths and
            // produced sixteen candidates for two real cameras, most of them
            // confident 404s that ate the probe budget.
            //
            // So a family match is required whenever the page offers a
            // choice of hosts. Only a page with exactly one host has no
            // choice to get wrong, and that is the simple single-camera case
            // this fallback is for.
            let unambiguous = Set(hosts.map(\.value)).count == 1 ? hosts.first : nil
            guard let host = sameFamily ?? unambiguous else { continue }
            if let url = URL(string: unescape(host.value) + unescape(path.value)),
               !candidates.contains(url) {
                candidates.append(url)
            }
        }

        var live: [Stream] = []
        for url in candidates.prefix(probeLimit) where await answers(url) {
            live.append(Stream(url: url, label: name(from: url, index: live.count), isClip: false))
        }
        return live
    }

    /// A media host and a stream id in two script variables, joined by a
    /// path only the player script knows.
    ///
    /// This is ipcamlive's player page, and it is written as a site rule
    /// because it is one: `var address = 'http://s66.ipcamlive.com/'` and
    /// `var streamid = '42jy…'`, with the playlist at
    /// `streams/<id>/stream.m3u8` on that host. Measured 2026-09-05, that is
    /// roughly sixty of the guide's cameras — the largest family after
    /// Surfline and YouTube — every one of them a page this file could read
    /// nothing from, and every one a public HLS stream once the two halves
    /// are put together. `https` even where the page says `http`: the host
    /// answers both, and a television will not load the plain one.
    ///
    /// Probed before it is believed, like the split URLs above — the shape is
    /// a convention, not something the page literally says.
    private static func hostedStreams(in html: String) async -> [Stream] {
        var found: [Stream] = []
        for url in hostedStreamCandidates(in: html) where await answers(url) {
            found.append(Stream(url: url, label: name(from: url, index: found.count), isClip: false))
        }
        return found
    }

    static func hostedStreamCandidates(in html: String) -> [URL] {
        let hosts = matches(#"\baddress\s*=\s*["']https?://([^"'/\s]+)/?["']"#, in: html)
        let ids = matches(#"\bstreamid\s*=\s*["']([A-Za-z0-9_-]{6,})["']"#, in: html)
        guard let host = hosts.first, let id = ids.first else { return [] }
        return [URL(string: "https://\(host)/streams/\(id)/stream.m3u8")].compactMap { $0 }
    }

    /// The frame a player SDK would draw, from the id the page hands it.
    ///
    /// Angelcam's embed is one line — `new Angelcam.player('holder', { id:
    /// 'j3l74078lm' })` — and its SDK turns that into an iframe at
    /// `v.angelcam.com/iframe?v=<id>`, whose page carries the playlist. Pages
    /// that write the iframe themselves were already read (the frame is
    /// followed); pages that let the SDK write it found nothing, for want of
    /// the one URL the script would have built. So it is built here and
    /// followed the same way.
    static func embeddedPlayers(in html: String) -> [URL] {
        matches(#"Angelcam\.player\s*\([^)]*?\bid\s*:\s*["']([A-Za-z0-9]+)["']"#, in: html)
            .compactMap { URL(string: "https://v.angelcam.com/iframe?v=\($0)") }
    }

    /// Any HLS playlist written into the page whole.
    private static func playlists(in html: String) -> [Stream] {
        matches(#"(https?://[^"'\s\\<>]+?\.m3u8[^"'\s\\<>]*)"#, in: html)
            .compactMap { URL(string: unescape($0)) }
            .enumerated()
            .map { Stream(url: $1, label: name(from: $1, index: $0), isClip: false) }
    }

    /// A media path written relative to the page.
    ///
    /// The smallest operator page there is — measured on nationalwebcam.com,
    /// Old Harbor on Block Island: a `<video>`, hls.js from a CDN, and
    /// `var videoSrc = '/hls/stream.m3u8'`. Nothing above could see it. The
    /// whole-URL reader wants a scheme and a host, the `<video>` reader wants
    /// a `src` the script never writes, and the array reader wants two names.
    /// One quoted path is what a page serving its own stream from its own
    /// box writes, and it resolves against the page like any other link.
    ///
    /// Only paths: a leading slash, a dot, or a bare filename. A quoted
    /// string with a `+` or a `${` in it is script assembling a URL, not a
    /// URL, and is left to the readers that understand the assembly.
    private static func relativeMedia(in html: String, base: URL) -> [Stream] {
        matches(#"["']((?:\.{0,2}/|//)?[A-Za-z0-9_./%-]+\.(?:m3u8|mp4|m4v|mov)(?:\?[^"'\s<>]*)?)["']"#,
                in: html)
            .filter { !$0.contains("+") && !$0.contains("${") && !$0.hasPrefix("http") }
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .filter { $0.scheme?.hasPrefix("http") == true }
            .enumerated()
            .map { Stream(url: $1, label: name(from: $1, index: $0),
                          isClip: !$1.absoluteString.contains(".m3u8")) }
    }

    /// The standard ways a page declares its own media to anything that is
    /// not a browser: Open Graph, Twitter's player card, schema.org.
    private static func metaDeclared(in html: String, base: URL) -> [Stream] {
        let patterns = [
            #"<meta[^>]+property\s*=\s*["']og:video(?::secure_url|:url)?["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']og:video(?::secure_url|:url)?["']"#,
            #"<meta[^>]+name\s*=\s*["']twitter:player:stream["'][^>]+content\s*=\s*["']([^"']+)["']"#,
            #""contentUrl"\s*:\s*"([^"]+)""#,
        ]
        return patterns
            .flatMap { matches($0, in: html) }
            .map(unescape)
            .filter { isPlayable($0) }
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .enumerated()
            .map { Stream(url: $1, label: name(from: $1, index: $0), isClip: !$1.absoluteString.contains(".m3u8")) }
    }

    /// A `<video>` or `<source>`, which is how a small operator who has never
    /// heard of HLS puts a camera on the web.
    private static func videoElements(in html: String, base: URL) -> [Stream] {
        matches(#"<(?:video|source)[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#, in: html)
            // A src built by script — `"'+ clipUrls[0] + '"` — is a fragment
            // of JavaScript, not a URL. `mediaArrays` is what that page needs.
            .filter { !$0.contains("+") && isPlayable($0) }
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .enumerated()
            .map { Stream(url: $1, label: name(from: $1, index: $0),
                          isClip: !$1.absoluteString.contains(".m3u8")) }
    }

    /// A script array of media filenames.
    ///
    /// Montauk Point Lighthouse's five angles are `clipUrls = ['northside.mp4',
    /// …]`, and an earlier version of this reader matched that variable name
    /// literally — a site hack wearing a generic coat, blind the moment they
    /// rename it and useless for anyone else. This matches the *shape*: any
    /// bracketed list holding two or more media names, wherever it appears
    /// and whatever it is assigned to.
    private static func mediaArrays(in html: String, base: URL) -> [Stream] {
        var found: [Stream] = []
        for body in matches(#"\[([^\[\]]{4,2000})\]"#, in: html) {
            let names = matches(#"['"]([^'"\s]+\.(?:mp4|m4v|mov|m3u8))['"]"#, in: body)
            // Two is the threshold: one filename in brackets is as likely to
            // be an index into something as a playlist.
            guard names.count >= 2 else { continue }
            for name in names {
                guard let url = URL(string: name, relativeTo: base)?.absoluteURL else { continue }
                found.append(Stream(url: url,
                                    label: Self.name(from: url, index: found.count),
                                    isClip: !name.contains(".m3u8")))
            }
            // The first qualifying array wins. A page with two of them is
            // more likely to hold one playlist and one list of adverts than
            // two sets of camera angles.
            if !found.isEmpty { break }
        }
        return found
    }

    private static func iframes(in html: String, base: URL) -> [URL] {
        matches(#"<iframe[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#, in: html)
            .map(unescape)
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .filter { $0.scheme?.hasPrefix("http") == true }
    }

    // MARK: Plumbing

    private static func isPlayable(_ text: String) -> Bool {
        [".m3u8", ".mp4", ".m4v", ".mov"].contains { text.contains($0) }
    }

    /// A name for the arrows to show.
    ///
    /// The filename, tidied — "northside.mp4" is Northside, and operators
    /// name these after what they point at more often than not. Numeric ids
    /// like EarthCam's "9974.flv" carry nothing, so those fall back to a
    /// position, which at least tells a rider where they are in the list.
    private static func name(from url: URL, index: Int) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty,
              cleaned.rangeOfCharacter(from: .letters) != nil,
              cleaned.count <= 24,
              !["playlist", "chunklist", "index", "master", "stream", "live"].contains(cleaned.lowercased())
        else { return "Camera \(index + 1)" }
        return cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A ranged GET rather than HEAD: some of these CDNs answer HEAD with 405
    /// while serving the body perfectly well, so asking for the first bytes is
    /// the honest test of "will this play".
    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue("AppleCoreMedia/1.0.0 (Apple TV; U; CPU OS 18_0 like Mac OS X)",
                         forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode
        else { return false }
        return (200 ..< 300).contains(code)
    }

    /// A key/value match, where it was found, and the key's family.
    ///
    /// The family is the key with its role stripped off —
    /// `html5_streamingdomain` and `html5_streampath` are both `html5`, a
    /// bare `domain` is nothing — which is how two halves of one URL are
    /// recognised as belonging to each other.
    private static func keyed(_ pattern: String, in text: String)
    -> [(family: String, value: String, at: Int)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 2,
                  let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text)
            else { return nil }
            var family = String(text[key]).lowercased()
            for role in ["streamingdomain", "streampath", "domain", "path"] {
                if let cut = family.range(of: role) { family.removeSubrange(cut) }
            }
            return (family.trimmingCharacters(in: CharacterSet(charactersIn: "_-")),
                    String(text[value]), match.range.location)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[captured])
        }
    }

    /// These arrive inside JSON and inside HTML attributes, escaped both ways
    /// — and sometimes escaped twice.
    ///
    /// The `\uXXXX` pass is general rather than the single `&` it used to
    /// be: Angelcam escapes the hyphens in its own hostname as `-`, which
    /// no amount of guessing at individual sequences would have caught.
    ///
    /// Any run of backslashes counts as one. wetter.com writes its player
    /// config as JSON inside a JavaScript string, so a slash arrives as
    /// `\\\/` and a hyphen as `\\u002D`; peeling one layer left a stray
    /// backslash in the URL, and a URL pattern that (rightly) refuses
    /// backslashes stopped dead at it. There is no page on which two
    /// backslashes before a slash mean anything but "a slash, quoted twice".
    private static func unescape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&amp;", with: "&")
        if let slashes = try? NSRegularExpression(pattern: #"\\+/"#) {
            out = slashes.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                   withTemplate: "/")
        }
        guard out.contains("\\u"),
              let regex = try? NSRegularExpression(pattern: #"\\+u([0-9a-fA-F]{4})"#)
        else { return out }
        let range = NSRange(out.startIndex ..< out.endIndex, in: out)
        for match in regex.matches(in: out, range: range).reversed() {
            guard let digits = Range(match.range(at: 1), in: out),
                  let scalar = UInt32(out[digits], radix: 16),
                  let character = Unicode.Scalar(scalar),
                  let whole = Range(match.range, in: out)
            else { continue }
            out.replaceSubrange(whole, with: String(Character(character)))
        }
        return out
    }
}
