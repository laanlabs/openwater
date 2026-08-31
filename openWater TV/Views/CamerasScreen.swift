import AVKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The cameras near your spots, and only the ones a television can show.
///
/// The phone plays a YouTube cam in a web view and hands everything else to
/// Safari, which between them cover the whole collection. tvOS has neither
/// WebKit nor SafariServices, so the honest set here is much smaller: the cams
/// that publish an HLS stream, and the ones that publish a JPEG they overwrite.
/// Roughly one in eleven.
///
/// The alternative was to list them all and grey out the rest. A row that
/// cannot be pressed is worse on a television than no row at all — there is no
/// tooltip, no long-press, nothing to explain itself — so the ones that do not
/// play are simply not here, and the empty state says why.
struct CamerasScreen: View {

    @Environment(SpotGuideStore.self) private var guide

    @State private var cams: [SpotGuideStore.GuideResource] = []
    @State private var isSearching = true

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 40)]

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView()
                } else if cams.isEmpty {
                    EmptyCams(hasFavorites: !guide.favorites.isEmpty)
                } else {
                    grid
                }
            }
        }
        .task(id: guide.favorites.map(\.spotId).joined()) {
            isSearching = true
            defer { isSearching = false }
            var found: [String: SpotGuideStore.GuideResource] = [:]
            for spot in guide.favorites {
                for cam in await guide.nearbyResources(to: spot, radius: 60_000)
                where cam.kind == .camera && cam.playback != nil {
                    // Two spots on the same stretch of coast pull the same
                    // cams; the nearer claim wins so the distance shown is
                    // true of the row it sits on.
                    if let existing = found[cam.id], existing.metres <= cam.metres { continue }
                    found[cam.id] = cam
                }
            }
            cams = found.values.sorted { $0.metres < $1.metres }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(cams) { CamCard(cam: $0) }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - One camera in the grid

/// A still with the name under it.
///
/// Surfline publishes a snapshot beside every stream it publishes, so most
/// cards here are the actual water rather than a placeholder — which is the
/// difference between choosing a camera and guessing at one.
struct CamCard: View {

    let cam: SpotGuideStore.GuideResource

    @State private var isWatching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only the picture goes inside the card button. tvOS's card style
            // lifts and clips what it is given, and a caption inside it gets
            // cropped at the edges as the card scales under focus.
            Button { isWatching = true } label: {
                ZStack {
                    Color.black
                    if let still = cam.stillUrl {
                        AsyncImage(url: still) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 420, height: 236)
                .clipped()
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(cam.displayName)
                    .font(.system(size: 24, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if case .stream = cam.playback {
                        Text("LIVE")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(Format.distance(cam.metres, unit: .imperial))
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 420, alignment: .leading)
        }
        .fullScreenCover(isPresented: $isWatching) {
            CamPlayer(cam: cam)
        }
    }
}

// MARK: - Watching one

/// Full screen, and whichever of the two things it is.
struct CamPlayer: View {

    let cam: SpotGuideStore.GuideResource

    var body: some View {
        switch cam.playback {
        case .stream(let url):
            // No custom headers. Surfline's CDN refuses a browser user agent
            // and accepts AVPlayer's own, which is exactly what this sends.
            LiveStream(url: url)
                .ignoresSafeArea()
        case .still(let url):
            RefreshingStill(url: url, name: cam.displayName)
                .ignoresSafeArea()
        case nil:
            // Unreachable: the lists only carry cams that play.
            Color.black.ignoresSafeArea()
        }
    }
}

private struct LiveStream: View {

    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let player = AVPlayer(url: url)
                // A live cam has no sound worth hearing and a living room has
                // somebody else in it.
                player.isMuted = true
                player.play()
                self.player = player
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}

/// A JPEG the operator overwrites, re-fetched on a timer.
///
/// Cache-busted per pass: these are served with generous cache headers by
/// hosts that never expected anybody to watch them, and without this the
/// picture is a still life.
private struct RefreshingStill: View {

    let url: URL
    let name: String

    @State private var tick = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            AsyncImage(url: bust(url, tick)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
            }
            .id(tick)
            Text(name)
                .font(.system(size: 28, weight: .semibold))
                .padding(28)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick += 1
            }
        }
    }

    private func bust(_ url: URL, _ tick: Int) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "ow", value: "\(tick)")]
        return parts.url ?? url
    }
}

// MARK: - When there is nothing to show

private struct EmptyCams: View {

    let hasFavorites: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.slash")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text(hasFavorites ? "No cameras your Apple TV can play" : "Save a spot first")
                .font(.system(size: 42, weight: .bold))
            Text(hasFavorites
                 ? "Most cameras in the guide are web pages, and an Apple TV has no\nbrowser to open them with. The ones that publish a video stream\nor a still image play here — there are none near your spots.\nThey are all on your phone."
                 : "Cameras are found near the spots you save.")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}
