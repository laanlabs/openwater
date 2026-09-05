import Foundation
import Testing
@testable import OpenWaterSpots

/// The page readers, against the pages that taught them.
///
/// Each fixture is an operator's page as it stood the day its rule was
/// written, cut down to the lines that matter. The network half — fetching,
/// probing, following iframes — is not under test here; what is pinned is
/// that a given shape of page yields the stream it advertises.
@MainActor
struct WebcamStreamTests {

    /// nationalwebcam.com, Old Harbor on Block Island, 2026-09-05: a
    /// `<video>` with no `src`, hls.js from a CDN, and the playlist written
    /// once as a root-relative path in a script variable. The one camera the
    /// rider named when asking for a more robust reader.
    static let nationalWebcam = """
    <!DOCTYPE html>
    <html><head><title>Old Harbor, Block Island</title></head>
    <body style="margin:0; background:black;">
    <video id="video" autoplay muted playsinline style="width:100%; height:auto;"></video>
    <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
    <script>
        var video = document.getElementById('video');
        var videoSrc = '/hls/stream.m3u8';
        function startStream() {
            if (Hls.isSupported()) {
                var hls = new Hls({ liveSyncDurationCount: 1 });
                hls.loadSource(videoSrc);
                hls.attachMedia(video);
            } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                video.src = videoSrc;
            }
        }
        startStream();
    </script>
    </body></html>
    """

    @Test("A playlist written as a root-relative path resolves against the page")
    func relativePlaylist() {
        let base = URL(string: "https://nationalwebcam.com/")!
        let found = WebcamStream.read(WebcamStream.prepared(Self.nationalWebcam), base: base)
        #expect(found.map(\.url.absoluteString) == ["https://nationalwebcam.com/hls/stream.m3u8"])
        #expect(found.first?.isClip == false)
    }

    @Test("A relative path resolves against the page's directory, not its root")
    func relativeToDirectory() {
        let base = URL(string: "https://example.org/cams/harbor/index.html")!
        let found = WebcamStream.read(#"<script>player.load("live/playlist.m3u8")</script>"#, base: base)
        #expect(found.map(\.url.absoluteString) == ["https://example.org/cams/harbor/live/playlist.m3u8"])
    }

    @Test("Script that assembles a URL is not mistaken for one")
    func assembledURLIsSkipped() {
        let base = URL(string: "https://example.org/")!
        let page = #"""
        var src = '/streams/' + camId + '.m3u8';
        var other = `${host}/live.m3u8`;
        """#
        #expect(WebcamStream.read(page, base: base).isEmpty)
    }

    /// ipcamlive's player page, 2026-09-05 — the guide's largest family of
    /// non-YouTube cameras. Two script variables and a convention.
    @Test("ipcamlive's host and stream id become one https playlist")
    func ipcamlive() {
        let page = #"""
        var alias = '57605d15d7d0e';
        var servicetype = 'S';
        var available = 1;
        var address = 'http://s66.ipcamlive.com/';
        var streamid = '42jygg3cfmyzbuqxo';
        var token = 'I5fuZuhkH6JgU7K/pXJUKvY7vDzs5WLyPr5BeZ1mrx4=';
        var websocketport = '6004';
        """#
        #expect(WebcamStream.hostedStreamCandidates(in: page).map(\.absoluteString)
                == ["https://s66.ipcamlive.com/streams/42jygg3cfmyzbuqxo/stream.m3u8"])
        #expect(WebcamStream.hostedStreamCandidates(in: "var address = 'x'; var nothing = 1;").isEmpty)
    }

    /// nsbashland.com's bay camera: the Angelcam SDK given only an id.
    @Test("An Angelcam SDK embed yields the frame its script would draw")
    func angelcamSDK() {
        let page = #"<div id="player_nsb-baycam"></div> <script> new Angelcam.player('player_nsb-baycam', { id: 'j3l74078lm' }); </script>"#
        #expect(WebcamStream.embeddedPlayers(in: page).map(\.absoluteString)
                == ["https://v.angelcam.com/iframe?v=j3l74078lm"])
    }

    /// wetter.com, 2026-09-05: JSON inside a JavaScript string, so every
    /// slash is quoted twice and the hyphens arrive as `\\u002D`.
    @Test("A URL escaped twice over is still one URL")
    func doubleEscaped() {
        let raw = #""source":"https:\\\/\\\/dc1.livespotting.com\\\/memfs\\\/c61c\\u002D68a3\\\/live\\\/main.m3u8\\u003Ftoken\\u003Dabc.def""#
        let found = WebcamStream.read(WebcamStream.prepared(raw), base: URL(string: "https://www.wetter.com/")!)
        #expect(found.map(\.url.absoluteString)
                == ["https://dc1.livespotting.com/memfs/c61c-68a3/live/main.m3u8?token=abc.def"])
    }

    /// reservations.palmettodunes.com lists its cameras as playlists outright.
    @Test("A link that is already a playlist is the stream")
    func directPlaylist() {
        let url = URL(string: "https://reservations.palmettodunes.com/live/SCMBasin.stream/playlist.m3u8")!
        #expect(WebcamStream.directMedia(url)?.url == url)
        #expect(WebcamStream.directMedia(url)?.isClip == false)
        #expect(WebcamStream.directMedia(URL(string: "https://example.org/cam.html")!) == nil)
    }

    @Test("A whole URL is not reported twice by the relative reader")
    func wholeURLOnce() {
        let base = URL(string: "https://example.org/")!
        let page = #"<script>hls.loadSource("https://cdn.example.net/live/index.m3u8")</script>"#
        let found = WebcamStream.read(page, base: base)
        #expect(found.map(\.url.absoluteString) == ["https://cdn.example.net/live/index.m3u8"])
    }
}
