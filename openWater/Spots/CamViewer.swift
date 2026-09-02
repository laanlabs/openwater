import AVKit
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
private struct CamResolver: View {

    let name: String
    let url: URL

    /// Nil while reading; then the streams found, empty if none.
    @State private var streams: [WebcamStream.Stream]?

    var body: some View {
        Group {
            switch streams {
            case .none:
                ZStack { Color.black; ProgressView().tint(.white) }
                    .ignoresSafeArea()
                    .task { streams = await WebcamStream.find(at: url) }
            case .some(let found) where found.isEmpty:
                SafariView(url: url).ignoresSafeArea()
            case .some(let found):
                CamStreamPlayer(streams: found, name: name)
            }
        }
    }
}

/// A cam with one or more streams, and arrows to move between them.
///
/// A site like EarthCam lists every camera at a place and Montauk Point
/// Lighthouse publishes five angles; playing only the first throws the rest
/// away. So the chevrons — and a horizontal swipe — step through them, the
/// way the television does it with the remote's arrows.
private struct CamStreamPlayer: View {

    let streams: [WebcamStream.Stream]
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var player: AVPlayer?
    /// Held so a looping clip's looper is not deallocated mid-play.
    @State private var looper: AVPlayerLooper?

    private var current: WebcamStream.Stream { streams[min(index, streams.count - 1)] }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .background(Color.black)
                .overlay(alignment: .bottom) { pager }
                .navigationTitle(current.label.isEmpty ? name : current.label)
                .navigationBarTitleDisplayMode(.inline)
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
        .task(id: index) { load() }
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
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

    private func step(_ delta: Int) {
        guard streams.count > 1 else { return }
        index = (index + delta + streams.count) % streams.count
    }

    private func load() {
        player?.pause()
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
