import AVKit
import Combine
import OpenWaterCore
import OpenWaterSpots
import SafariServices
import SwiftUI
import WebKit

/// A cam watched inside the app.
///
/// Launching another app for a ten-second glance at the water is a context
/// switch nobody asked for. YouTube links play in an embedded player — the
/// id is recoverable from every shape a cam link takes, and core's
/// `VideoLink` refuses to guess — and everything else opens in the in-app
/// browser, so checking a cam never leaves the app either way.
struct CamViewerSheet: View {

    let name: String
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let videoID = VideoLink.youTubeID(from: url) {
            NavigationStack {
                YouTubeEmbedView(videoID: videoID)
                    .background(Color.black)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        } else {
            CamResolver(name: name, url: url)
        }
    }
}

/// Read the page for a playable stream; play it if there is one, otherwise
/// hand off to the in-app browser.
///
/// The read is a single page fetch, so a brief spinner covers it — and for
/// the many cams that turn out to be plain web pages, that is one second
/// before Safari opens, which is a fair price for the ones that turn out to
/// be watchable in place.
///
/// **A way out from the first frame.** This used to be a bare black screen
/// with a spinner until the read came back, inside a full-screen cover that
/// nothing could dismiss. A page that hangs — and a webcam page hosted on a
/// box in a beach hut hangs more often than most — kept a rider staring at
/// the spinner with no Done, no swipe and no timeout, which is exactly how
/// it was reported. So the bar and its Done are there before anything is
/// known, the read is given a bounded wait, and past that wait the page
/// opens in the browser instead.
private struct CamResolver: View {

    let name: String
    let url: URL

    @Environment(\.dismiss) private var dismiss

    /// Nil while reading; then the streams found, empty if none.
    @State private var streams: [WebcamStream.Stream]?

    /// How long the read may take before the browser is the better answer.
    /// Long enough for a slow operator page and one embedded player; short
    /// enough that nobody wonders whether the app has stopped.
    private static let patience: Duration = .seconds(12)

    var body: some View {
        Group {
            switch streams {
            case .none:
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().tint(.white)
                            Text("Looking for the stream…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .navigationTitle(name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .bottomBar) {
                            // Offered during the wait, not only after it: a
                            // rider who knows this page opens fine in a
                            // browser should not have to sit out the read.
                            Button("Open the page instead") { streams = [] }
                        }
                    }
                }
                .task { streams = await Self.read(url) }
            case .some(let found) where found.isEmpty:
                SafariView(url: url).ignoresSafeArea()
            case .some(let found):
                CamStreamPlayer(streams: found, name: name, page: url)
            }
        }
    }

    /// The read, bounded. Whichever finishes first wins — the streams, or the
    /// clock saying "enough" — and the loser is cancelled so a hung fetch is
    /// not left running behind the browser.
    private static func read(_ url: URL) async -> [WebcamStream.Stream] {
        await withTaskGroup(of: [WebcamStream.Stream].self) { group in
            group.addTask { await WebcamStream.find(at: url) }
            group.addTask {
                try? await Task.sleep(for: patience)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }
}

/// A cam with one or more streams, and arrows to move between them.
///
/// A site like EarthCam lists every camera at a place and Montauk Point
/// Lighthouse publishes five angles; playing only the first throws the rest
/// away. So the chevrons — and a horizontal swipe — step through them, the
/// way the television does it with the remote's arrows.
///
/// **When the stream will not play, say so, and keep the door.** A playlist
/// the page advertised can be signed, expired, geo-fenced or simply off air,
/// and `AVPlayer` reports that as a failed item behind the system player's
/// own small error. The Done button in the bar was the only way out, and
/// the system player's chrome sits over that bar. So a failed item puts up
/// this screen's own notice — what happened, the page as the alternative,
/// and Done — on top of everything.
private struct CamStreamPlayer: View {

    let streams: [WebcamStream.Stream]
    let name: String
    /// The operator's page, for when the stream it advertised will not play.
    let page: URL

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var player: AVPlayer?
    /// Held so a looping clip's looper is not deallocated mid-play.
    @State private var looper: AVPlayerLooper?
    /// The current item reported failure — see `watch`.
    @State private var didFail = false
    /// The rider gave up on the stream and asked for the page.
    @State private var wantsPage = false

    private var current: WebcamStream.Stream { streams[min(index, streams.count - 1)] }

    var body: some View {
        if wantsPage {
            SafariView(url: page).ignoresSafeArea()
        } else {
            NavigationStack {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
                    .background(Color.black)
                    .overlay(alignment: .bottom) { if !didFail { pager } }
                    .overlay { if didFail { failure } }
                    .navigationTitle(current.label.isEmpty ? name : current.label)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                step(value.translation.width < 0 ? 1 : -1)
                            }
                    )
            }
            .task(id: index) { await load() }
            .onDisappear {
                player?.pause()
                player = nil
                looper = nil
            }
        }
    }

    /// The camera picker, shown only when a site has more than one.
    @ViewBuilder private var pager: some View {
        if streams.count > 1 {
            HStack(spacing: 24) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.system(size: 34))
                }
                Text("\(index + 1) of \(streams.count)")
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                Button { step(1) } label: {
                    Image(systemName: "chevron.right.circle.fill").font(.system(size: 34))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 30)
            .shadow(radius: 6)
        }
    }

    /// The stream did not play. Not an apology and not a dead end: the next
    /// angle if there is one, the page if there is not, and Done regardless.
    private var failure: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "video.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("This stream isn't playing")
                    .font(.title3.weight(.semibold))
                Text("The page pointed here, but the video didn't come through — it may be off air or need a browser.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                VStack(spacing: 12) {
                    if streams.count > 1 {
                        Button("Try the next camera") { step(1) }
                            .buttonStyle(.borderedProminent)
                    }
                    if streams.count > 1 {
                        Button("Open the page instead") { wantsPage = true }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Open the page instead") { wantsPage = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
        }
    }

    private func step(_ delta: Int) {
        guard streams.count > 1 else { return }
        index = (index + delta + streams.count) % streams.count
    }

    private func load() async {
        player?.pause()
        didFail = false
        let item = AVPlayerItem(url: current.url)
        if current.isClip {
            // A recorded clip loops seamlessly, so an angle keeps playing
            // rather than stopping after its half a minute.
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            looper = nil
            player = AVPlayer(playerItem: item)
        }
        player?.play()
        await watch(item)
    }

    /// Wait for the item to say whether it will play. Lives with `load`'s
    /// task, so stepping to another angle retires it along with the player.
    private func watch(_ item: AVPlayerItem) async {
        for await status in item.publisher(for: \.status).values {
            if status == .failed { didFail = true; return }
            if status == .readyToPlay { return }
        }
    }
}

/// YouTube's embed player in a web view — inline, autoplaying muted, which
/// is the right way for a live cam to arrive: the picture immediately, the
/// sound only if asked for.
private struct YouTubeEmbedView: UIViewRepresentable {

    let videoID: String

    final class Coordinator { var loadedID: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Zoom like Safari would: checking a cam is exactly the moment a
        // rider wants to magnify one corner of the frame, and a page's own
        // scale limits should not be able to say no.
        configuration.ignoresViewportScaleLimits = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        // Scrolling stays on for the pan half of pinch-and-pan; at 1× the
        // page fits exactly, so nothing moves until a zoom gives it
        // somewhere to go.
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        // An iframe inside a page with a real base URL, never the /embed
        // address as the top-level document — YouTube refuses to configure
        // the player (error 153) when the embed arrives with no referring
        // page. The id is core-validated to the eleven-character alphabet,
        // so interpolating it into markup is safe.
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(videoID)?playsinline=1&autoplay=1&mute=1&rel=0"
                allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://openwaterapp.com"))
    }
}

/// Safari inside the app — cookies, scripts and logins intact, without
/// actually leaving.
struct SafariView: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
