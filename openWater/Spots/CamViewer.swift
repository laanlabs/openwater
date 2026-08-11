import OpenWaterCore
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
            // The in-app browser brings its own chrome and Done button.
            SafariView(url: url)
                .ignoresSafeArea()
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
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
        <meta name="viewport" content="initial-scale=1, maximum-scale=1">
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
