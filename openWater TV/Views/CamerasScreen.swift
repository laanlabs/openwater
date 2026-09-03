import AVKit
import MapKit
import OpenWaterCore
import UIKit
import OpenWaterSpots
import SwiftUI

/// Every camera in your area, and an honest label on each.
///
/// "Your area" is whatever the map is looking at — the box's own coarse fix,
/// or the place somebody typed on the map tab, held in `TVLocation` so both
/// tabs agree about where here is. A rider who moves the map to Tarifa and
/// comes over to the cameras expects Tarifa's, not the ones near a spot they
/// starred in Maine. Where the box has no place at all the list falls back to
/// the saved spots, which is the only other coast it knows about.
///
/// **Why the list is now all of them.** tvOS has no WebKit and no
/// SafariServices, so only about one cam in eleven — the ones publishing an
/// HLS stream or a JPEG they overwrite — can play on this device. This screen
/// used to hide the rest, on the argument that a row which cannot be pressed
/// is worse on a television than no row at all. That argument was right about
/// the *dead end* and wrong about the *row*: the cams a rider actually knows
/// by name are mostly YouTube pages, and a list that silently omits them reads
/// as a guide that has never heard of the local water.
///
/// So every camera is listed, and the ones this box cannot play lead to a QR
/// code instead of a player. The phone in the room is the browser the
/// television does not have, and pointing it at the screen is one gesture —
/// which is a real answer, where a greyed-out row was not.
///
/// **YouTube is handed to YouTube's own app, not decoded here.** Google ships
/// a tvOS YouTube app and it plays these streams perfectly; what does not
/// exist is a YouTube player a *third party* may embed. On the phone the
/// sanctioned route is the IFrame player in a web view, which is exactly what
/// `CamViewerSheet` does — and tvOS has no web view at all, so that route is
/// simply absent rather than merely awkward.
///
/// The remaining route is to impersonate YouTube's own client against their
/// private player endpoint and pull an HLS manifest out of it. Measured
/// against a live cam in the guide: the manifest is no longer in the watch
/// page at all, so even the old scrape is already dead, and what is left
/// breaks YouTube's terms and risks a shipped app. So this hands the video to
/// the app that is allowed to play it, and keeps a code for the phone when
/// that app is not installed.
struct CamerasScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location

    @State private var cams: [SpotGuideStore.GuideResource] = []
    @State private var isSearching = true

    /// How far out "your area" reaches. Wider than the phone's forty
    /// kilometres because a television is not standing on the beach — the
    /// question here is which cams are on this coast, not which one is at the
    /// launch under your feet.
    private static let radius: Double = 80_000

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 40)]

    /// The map, over the grid.
    ///
    /// The grid is the tab and the map is a detail of it, rather than the two
    /// being equal halves of a switch. That way Menu means what it means
    /// everywhere else on this box — back to where I was — instead of leaving
    /// the tab entirely from a view a rider had switched into and would then
    /// have to switch out of.
    @State private var showsMap = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView()
                } else if cams.isEmpty {
                    // Only a *named* place goes into the sentence. The generic
                    // name a bare fix carries would turn "none near \(place)"
                    // into "none near Nearby".
                    EmptyCams(place: location.isChosen ? location.name : "",
                              hasSomewhere: location.here != nil || !guide.favorites.isEmpty)
                } else {
                    grid
                }
            }
            // Painted, not inherited. A tvOS window follows the box's own
            // Light/Dark setting, and on a Light Apple TV this screen came up
            // pale under white captions — reported from a real television and
            // invisible on a simulator, which is set to Dark. The app is dark
            // by construction, so it lays its own ground rather than trusting
            // the one underneath.
            .background(Color.black.ignoresSafeArea())
        }
        .fullScreenCover(isPresented: $showsMap) {
            CamsMapScreen(cams: cams)
        }
        .task(id: cams.isEmpty) {
            // The capture seam; see `TVScreenshotRoute`. Waits for the cams,
            // because a map of nothing is not a screenshot of anything.
            if TVScreenshotRoute.requested == .camerasMap, !cams.isEmpty {
                showsMap = true
            }
        }
        .task(id: areaKey) {
            isSearching = true
            defer { isSearching = false }
            var found: [String: SpotGuideStore.GuideResource] = [:]
            if let here = location.here {
                for cam in await guide.nearbyResources(near: here, radius: Self.radius)
                where cam.kind == .camera {
                    found[cam.id] = cam
                }
            } else {
                for spot in guide.favorites {
                    for cam in await guide.nearbyResources(to: spot, radius: 60_000)
                    where cam.kind == .camera {
                        // Two spots on the same stretch of coast pull the same
                        // cams; the nearer claim wins so the distance shown is
                        // true of the row it sits on.
                        if let existing = found[cam.id], existing.metres <= cam.metres { continue }
                        found[cam.id] = cam
                    }
                }
            }
            // Playable first, then by distance. Not distance alone: the point
            // of the tab is watching the water on this screen, and burying
            // the four cams that can do that under thirty that cannot is the
            // old bug with the order reversed.
            cams = found.values.sorted {
                if ($0.playback != nil) != ($1.playback != nil) { return $0.playback != nil }
                return $0.metres < $1.metres
            }
        }
    }

    /// What the list depends on: where here is, or — with nowhere at all —
    /// which spots are starred.
    private var areaKey: String {
        if let here = location.here {
            return String(format: "%.2f,%.2f", here.latitude, here.longitude)
        }
        return guide.favorites.map(\.spotId).joined()
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                mapButton
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(cams) { CamCard(cam: $0) }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }

    /// The way to the map, said in words.
    ///
    /// It was a pair of icons pinned above the grid in a top safe-area inset,
    /// and it was unreachable: on tvOS the tab bar owns Up, so Up from the
    /// first row of cards travelled straight past an inset into the tab bar,
    /// and nothing a rider pressed ever landed on it. Inside the scroll
    /// content it is simply the row above the cards, which Up finds because
    /// that is what Up does.
    ///
    /// One labelled button rather than two glyphs. A grid icon beside a map
    /// icon asked a rider to work out which of them was the state they were
    /// already in; the map is a place you go now, so the control says so.
    private var mapButton: some View {
        Button { showsMap = true } label: {
            Label("View on map", systemImage: "map")
                .font(.system(size: 26, weight: .medium))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - One camera in the grid

/// A still with the name under it, and what pressing it will do.
///
/// Surfline publishes a snapshot beside every stream it publishes and YouTube
/// publishes a poster frame for every stream on it, so nearly every card here
/// is the actual water rather than a placeholder — which is the difference
/// between choosing a camera and guessing at one. A badge under it says where
/// pressing it goes.
struct CamCard: View {

    let cam: SpotGuideStore.GuideResource

    /// How this draws. The resolving, the routes and the covers below are
    /// identical either way and deliberately stay in one place: a map pin that
    /// opened cameras through its own copy of `open()` would drift out of step
    /// with the grid the first time either of them changed.
    enum Style { case card, pin, bar }
    var style: Style = .card

    /// The pin the map's arrows are currently on. It wears its name and sits
    /// above its neighbours whether or not the remote is on it, because on
    /// this map the arrows do the choosing and focus is elsewhere — on the bar.
    var isStepped = false

    @AppStorage(TVSettings.playsYouTubeKey) private var playsYouTube = false

    /// Where pressing this card went. One optional rather than three Bools:
    /// a YouTube cam only learns which of these it is *after* a round trip,
    /// and three flags would let it be two things at once.
    @State private var route: Route?
    @State private var isResolving = false

    /// Only meaningful for `.pin`: a map pin wears its name while focused.
    @FocusState private var isPinFocused: Bool

    private enum Route: Identifiable {
        /// Something `AVPlayer` can open — the guide's own stream or still,
        /// or a manifest resolved a moment ago.
        case play(URL, isStill: Bool)
        /// What an operator's own page turned out to be showing — one
        /// camera or several, live or looping. See `WebcamStream`.
        case angles([WebcamStream.Stream])
        /// A code for a phone. Carries why the stream was not available, when
        /// one was actually asked for; nil when nothing was ever tried.
        case handoff(String?)

        var id: String {
            switch self {
            case .play(let url, _): url.absoluteString
            case .angles(let streams): streams.first?.id ?? "angles"
            case .handoff: "handoff"
            }
        }
    }

    private var isPlayable: Bool { cam.playback != nil }

    /// Whether this card will try to play a YouTube stream on this box. The
    /// switch is off until a rider turns it on — see `SettingsScreen`.
    private var willTryYouTube: Bool {
        playsYouTube && VideoLink.youTubeID(from: cam.url) != nil
    }

    var body: some View {
        Group {
            switch style {
            case .card: card
            case .pin: pin
            case .bar: barLabel
            }
        }
        .fullScreenCover(item: $route) { route in
            switch route {
            case .play(let url, let isStill):
                CamPlayer(url: url, isStill: isStill, name: cam.displayName)
            case .angles(let streams):
                CamAnglePlayer(streams: streams, name: cam.displayName)
            case .handoff(let whyNoStream):
                CamHandoff(cam: cam, whyNoStream: whyNoStream)
            }
        }
    }

    /// A camera on the map: a glyph, and its name only while it is focused.
    ///
    /// The name was on every pin to begin with and the map was unreadable —
    /// thirty capsules on one stretch of coast overlap into a wall of text,
    /// and the cams pile up densest exactly where the good water is. A dot is
    /// legible at any density, and the remote already says which one is meant.
    /// The stepped camera, named across the map's bottom bar, and pressable.
    /// Going through `CamCard` rather than a button of its own means watching
    /// from the map takes exactly the same route as watching from the grid.
    private var barLabel: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if isResolving {
                    ProgressView()
                } else {
                    Image(systemName: isPlayable ? "video.fill" : "qrcode")
                        .font(.system(size: 24))
                }
                Text(cam.displayName)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var pin: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                if isResolving {
                    ProgressView()
                } else {
                    Image(systemName: isPlayable ? "video.fill" : "qrcode")
                        .font(.system(size: 20))
                }
                if isPinFocused || isStepped {
                    Text(cam.displayName)
                        .font(.system(size: 20, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isPinFocused || isStepped ? 16 : 10)
            .padding(.vertical, 10)
            // Playable cams carry the tint. On a map the question is which of
            // these the television can actually show, and that has to survive
            // being read at three metres.
            .background(isPlayable ? Color.accentColor : Color.black.opacity(0.85),
                        in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(isPinFocused || isStepped ? 1 : 0.6),
                                      lineWidth: isPinFocused || isStepped ? 3 : 2))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .focused($isPinFocused)
        .scaleEffect(isPinFocused || isStepped ? 1.15 : 1)
        // The focused pin reads over its neighbours rather than under them,
        // which is the whole reason it is allowed to grow a name at all.
        .zIndex(isPinFocused || isStepped ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isPinFocused)
        .animation(.easeOut(duration: 0.15), value: isStepped)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only the picture goes inside the card button. tvOS's card style
            // lifts and clips what it is given, and a caption inside it gets
            // cropped at the edges as the card scales under focus.
            Button(action: open) {
                ZStack {
                    Color.black
                    if let preview = cam.previewUrl {
                        AsyncImage(url: preview) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: isPlayable ? "video.fill" : "qrcode")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    }
                    // The round trip is a second or two on a cold cam, and a
                    // card that does nothing for two seconds after a press
                    // reads as a card that did not take the press.
                    if isResolving {
                        Color.black.opacity(0.55)
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                .frame(width: 420, height: 236)
                .clipped()
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(cam.displayName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    badge
                    Text(Format.distance(cam.metres, unit: UnitPreferences.forThisDevice.distance))
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 420, alignment: .leading)
        }
    }

    /// What a press does, in the order the answers are cheap.
    ///
    /// The guide's own stream or still needs nothing asked of anybody. A
    /// YouTube cam with the switch on costs one request, and a failure is
    /// not an error state — it is the code, which always works.
    private func open() {
        switch cam.playback {
        case .stream(let url): route = .play(url, isStill: false)
        case .still(let url):  route = .play(url, isStill: true)
        case nil:
            // Not YouTube: read the operator's own page for whatever it hands
            // its own player. Costs one request and needs no switch — see
            // `WebcamStream` for why this is a different question entirely.
            guard VideoLink.youTubeID(from: cam.url) != nil else {
                isResolving = true
                Task {
                    let streams = await WebcamStream.find(at: cam.url)
                    isResolving = false
                    route = streams.isEmpty ? .handoff(nil) : .angles(streams)
                }
                return
            }
            guard willTryYouTube, let id = VideoLink.youTubeID(from: cam.url) else {
                route = .handoff(nil)
                return
            }
            isResolving = true
            Task {
                let manifest = await YouTubeStream.manifest(for: id)
                isResolving = false
                if let manifest {
                    route = .play(manifest, isStill: false)
                } else {
                    // The reason travels to the screen the rider is about to
                    // be looking at. A switch that silently does nothing is
                    // indistinguishable from a switch that is not wired up,
                    // which is exactly how this was first reported.
                    route = .handoff(YouTubeStream.lastFailure)
                }
            }
        }
    }

    /// Said before it is pressed, not after. On a television the cost of
    /// finding out is a full-screen cover and a trip back with the Menu
    /// button, so the row has to promise the right thing.
    @ViewBuilder private var badge: some View {
        switch cam.playback {
        case .stream:
            Text("LIVE")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color.accentColor)
        case .still:
            Text("PHOTO")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color.accentColor)
        case nil where willTryYouTube:
            // Promised, not guaranteed: the resolve can still come back with
            // nothing, and then the code appears instead. "LIVE" would be a
            // stronger claim than this row can make.
            Label("YouTube", systemImage: "play.circle")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color.accentColor)
        case nil:
            Label(VideoLink.youTubeID(from: cam.url) != nil ? "YouTube" : "On your phone",
                  systemImage: "iphone")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Watching one

/// Full screen, and whichever of the two things it is.
struct CamPlayer: View {

    /// Already resolved by the caller. The card knows whether this came from
    /// the guide or from a manifest fetched a moment ago; the player does not
    /// need to, and asking `cam.playback` again here would have missed the
    /// YouTube case entirely.
    let url: URL
    let isStill: Bool
    let name: String

    var body: some View {
        Group {
            if isStill {
                RefreshingStill(url: url, name: name)
            } else {
                // No custom headers. Surfline's CDN refuses a browser user
                // agent and accepts AVPlayer's own, which is exactly what
                // this sends; a YouTube manifest is happy either way.
                LiveStream(url: url)
            }
        }
        .ignoresSafeArea()
        .menuBackHint()
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

// MARK: - Handing one to a phone

/// The cam this box cannot play, as a code and a sentence.
///
/// Deliberately not an apology. The screen leads with the camera's own name
/// and where it is, then says plainly what it is — a YouTube stream, a
/// provider's page — and gives the one thing that actually opens it. The URL
/// is printed under the code as well: a code that will not scan in a bright
/// room is still a thing somebody can type.
private struct CamHandoff: View {

    let cam: SpotGuideStore.GuideResource
    /// Why the stream could not be resolved, when one was asked for. Nil when
    /// the switch is off and nothing was ever tried.
    var whyNoStream: String?

    private var youTubeID: String? { VideoLink.youTubeID(from: cam.url) }
    private var isYouTube: Bool { youTubeID != nil }

    /// Whether the YouTube app took the video. Nil until it has been asked —
    /// which is the only way to find out, since answering `canOpenURL`
    /// honestly would need the scheme declared in the Info.plist and would
    /// still be a guess about a household's installed apps.
    @State private var handoffFailed = false

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 22) {
                Text(cam.displayName)
                    .font(.system(size: 54, weight: .bold))
                    .lineLimit(3)
                HStack(spacing: 16) {
                    // "YouTube", not "youtube.com". A hostname is what the
                    // link says; the brand is what the reader knows.
                    Label(isYouTube ? "YouTube" : cam.providerLabel,
                          systemImage: isYouTube ? "play.rectangle" : "globe")
                    Text(Format.distance(cam.metres, unit: UnitPreferences.forThisDevice.distance))
                }
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

                // Wrapped by the layout, not by hand. Hard breaks are right
                // for the centred empty states elsewhere in this app, where
                // the width is the screen; here the column is 760 points and
                // baked-in newlines came out as three ragged half-lines.
                Text(explanation)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if let detail = cam.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }

                if let whyNoStream {
                    // The switch was on and YouTube still said no. Printed
                    // rather than swallowed: `LOGIN_REQUIRED` means they now
                    // want attestation and this feature is finished, while
                    // "not live" means only that this camera is off air —
                    // and from a sofa those look identical without this line.
                    Label("No stream — \(whyNoStream)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(.top, 12)
                }

                if isYouTube {
                    if handoffFailed {
                        // Asked, and there was nothing to ask. Said once, in
                        // place of the button, rather than left as a control
                        // that quietly does nothing on every press.
                        Label("The YouTube app isn't on this Apple TV — use the code",
                              systemImage: "exclamationmark.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    } else {
                        Button("Open in YouTube", action: openInYouTube)
                            .padding(.top, 16)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)

            VStack(spacing: 18) {
                QRCodeCard(link: cam.url)
                Text("Point your phone's camera at the code")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(cam.url.absoluteString)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 440)
            }
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        // White on the black this screen paints, stated rather than
        // inherited. `.primary` follows the system appearance, and on a
        // television set to Light that is black — black text on a black
        // background, which is exactly how this was reported. `.secondary`
        // and `.tertiary` below resolve against this, so they come right
        // with it.
        .foregroundStyle(.white)
    }

    /// Hand the video to the app that is allowed to play it.
    ///
    /// `youtube://<id>` is the scheme YouTube's own apps register. The
    /// completion handler is the honest test of whether anything answered —
    /// no probing, no declared query schemes, just the result — and a false
    /// swaps the button for a sentence.
    private func openInYouTube() {
        guard let id = youTubeID,
              let deepLink = URL(string: "youtube://\(id)")
        else { return handoffFailed = true }
        UIApplication.shared.open(deepLink, options: [:]) { opened in
            guard !opened else { return }
            // Second chance on the https link: tvOS may route it as a
            // universal link even where the custom scheme is unregistered.
            UIApplication.shared.open(cam.url, options: [:]) { viaWeb in
                handoffFailed = !viaWeb
            }
        }
    }

    private var explanation: String {
        isYouTube
        ? "This one is a YouTube stream. No app but YouTube's own may play those on an Apple TV, so this hands it over — or scan the code and watch it on your phone."
        : "This one is a web page, and an Apple TV has no browser to open it with. Your phone does."
    }
}

// MARK: - When there is nothing to show

private struct EmptyCams: View {

    /// What to call the area that came up empty. Blank when the box has
    /// nowhere at all, which is a different sentence.
    let place: String
    let hasSomewhere: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.slash")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text(hasSomewhere ? "No cameras around here" : "Set a location first")
                .font(.system(size: 42, weight: .bold))
            Text(hasSomewhere
                 ? "The guide has no cameras \(place.isEmpty ? "in this area" : "near \(place)") at all —\nnot ones this Apple TV can play, and not ones to hand to a phone.\nMove the map somewhere else and come back."
                 : "Open the Map tab and say where you are. Cameras are found\naround it.")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(60)
    }
}
