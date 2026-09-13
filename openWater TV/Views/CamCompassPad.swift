import OpenWaterCore
import OpenWaterSpots
import SwiftUI

// MARK: - Where a camera leads

/// What pressing a camera turns out to open, worked out in one place.
///
/// The grid, the map's pins and the compass all open cameras, and they must
/// agree about it. They used not to: the grid read operators' pages and asked
/// YouTube, while the compass only offered cameras the guide already held a
/// stream or a still for — so a rider walking the coast skipped straight past
/// the YouTube cam at Main Beach that the grid would have played. Now a step
/// lands wherever a press on the grid would, including on a code for the phone.
enum CamRoute: Identifiable {
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

    /// The answer that needs nobody asked: the guide's own stream or still.
    static func immediate(for cam: SpotGuideStore.GuideResource) -> CamRoute? {
        switch cam.playback {
        case .stream(let url): .play(url, isStill: false)
        case .still(let url): .play(url, isStill: true)
        case nil: nil
        }
    }

    /// Whether finding out costs a round trip — a second or two on a cold
    /// cam, which the caller should cover with a spinner.
    static func needsRoundTrip(_ cam: SpotGuideStore.GuideResource, playsYouTube: Bool) -> Bool {
        guard immediate(for: cam) == nil else { return false }
        return VideoLink.youTubeID(from: cam.url) == nil || playsYouTube
    }

    /// What a press does, in the order the answers are cheap.
    ///
    /// The guide's own stream or still needs nothing asked of anybody. An
    /// operator's page costs one request and needs no switch. A YouTube cam
    /// with the switch on costs one request, and a failure is not an error
    /// state — it is the code, which always works.
    @MainActor
    static func resolve(_ cam: SpotGuideStore.GuideResource, playsYouTube: Bool) async -> CamRoute {
        if let now = immediate(for: cam) { return now }
        guard let id = VideoLink.youTubeID(from: cam.url) else {
            // Not YouTube: read the operator's own page for whatever it hands
            // its own player. See `WebcamStream` for why this is a different
            // question entirely.
            let streams = await WebcamStream.find(at: cam.url)
            return streams.isEmpty ? .handoff(nil) : .angles(streams)
        }
        guard playsYouTube else { return .handoff(nil) }
        if let manifest = await YouTubeStream.manifest(for: id) {
            return .play(manifest, isStill: false)
        }
        // The reason travels to the screen the rider is about to be looking
        // at. A switch that silently does nothing is indistinguishable from a
        // switch that is not wired up, which is exactly how this was first
        // reported.
        return .handoff(YouTubeStream.lastFailure)
    }

    /// What was on the glass, in words for a report. "The cam is black" is a
    /// different ticket when the black was a still, a YouTube manifest or a
    /// playlist read off the operator's page a minute ago.
    var summary: String {
        switch self {
        case let .play(url, isStill):
            "\(isStill ? "still" : "stream") \(url.absoluteString)"
        case .angles(let streams):
            "\(streams.count) read from the page — "
                + streams.prefix(4).map(\.url.absoluteString).joined(separator: ", ")
        case .handoff(let why):
            "a QR code for the phone" + (why.map { " (no stream: \($0))" } ?? "")
        }
    }
}

// MARK: - The stage

/// One camera full screen, and the corner that walks you to the next.
///
/// Hosts every shape a camera comes in — a live stream, a still, a page's
/// several angles, a code for the phone — under one set of controls, so the
/// compass and the menu are in the same corner whatever is playing and
/// whatever can't.
///
/// **Menu backs out a layer at a time.** An open compass folds first, then a
/// focused corner hands the remote back to the picture, and only from the
/// picture does Menu leave the camera. The corner's layers are heard on the
/// corner's own buttons (see `CamCorner.back`); the last one is said here,
/// because the players own the whole glass and a screen that owns the remote
/// has to give Menu back itself.
struct CamStage: View {

    /// Who has the remote. One value for the whole stage, so the picture can
    /// hand focus to the corner and the corner can hand it back.
    enum Focus: Hashable { case picture, compass, more }

    private enum Sheet: String, Identifiable {
        case source, report
        var id: String { rawValue }
    }

    let cam: SpotGuideStore.GuideResource

    @AppStorage(TVSettings.playsYouTubeKey) private var playsYouTube = false
    @Environment(\.dismiss) private var dismiss

    /// Where the compass is standing. Moves the instant an arrow is pressed,
    /// so the next press measures from here — a rider can walk three cameras
    /// east without waiting for the first two to load.
    @State private var here: SpotGuideStore.GuideResource
    /// What the glass is showing. Catches up with `here` once its route is
    /// known; until then the old picture stays up under a spinner.
    @State private var shown: SpotGuideStore.GuideResource
    @State private var route: CamRoute
    @State private var isResolving = false
    @State private var isCompassOpen = false
    @State private var sheet: Sheet?
    @FocusState private var focus: Focus?

    init(start: CamRoute, cam: SpotGuideStore.GuideResource) {
        self.cam = cam
        _here = State(initialValue: cam)
        _shown = State(initialValue: cam)
        _route = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black
            content
                .id(shown.id)
            if isResolving {
                Stepping(name: here.displayName)
            }
        }
        .overlay(alignment: .top) {
            // A focus section as wide as the screen, so Up from anywhere
            // lands in the corner — from the handoff's YouTube button on the
            // far left too, which tvOS's own search would never find.
            HStack {
                Spacer()
                CamCorner(here: here, isOpen: $isCompassOpen, focus: $focus,
                          hasPicture: hasPicture,
                          onPick: { here = $0 },
                          onSource: { sheet = .source },
                          onReport: { sheet = .report })
            }
            .padding(.top, 50)
            .padding(.trailing, 60)
            .focusSection()
        }
        .ignoresSafeArea()
        .onAppear { focus = .picture }
        .onExitCommand {
            if isCompassOpen { isCompassOpen = false } else { dismiss() }
        }
        // Esc on a keyboard, for an open compass wherever focus has got to.
        // From the picture it is left to the system, which leaves the camera.
        .onKeyPress(.escape) {
            guard isCompassOpen else { return .ignored }
            isCompassOpen = false
            return .handled
        }
        // And the cover may not close underneath an open compass: on tvOS a
        // full-screen cover treats Menu as a dismissal of its own, which is
        // how Back skipped the compass and went straight to the grid.
        .interactiveDismissDisabled(isCompassOpen)
        .onChange(of: isCompassOpen) { _, open in
            if !open { returnToPicture() }
        }
        .task(id: here.id) { await arrive() }
        .fullScreenCover(item: $sheet) { sheet in
            switch sheet {
            case .source: CamSourceCode(cam: shown)
            case .report: CamReportScreen(cam: shown, route: route)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case let .play(url, isStill: true):
            ZStack {
                RefreshingStill(url: url, name: shown.displayName)
                stillGlass
            }
            .menuBackHint()
        case let .play(url, isStill: false):
            // The one-angle case of the angle player, rather than the system
            // `VideoPlayer`: its transport bar eats the D-pad, and then Up
            // could never reach the corner.
            CamAnglePlayer(streams: [.init(url: url, label: "", isClip: false)],
                           name: shown.displayName, focus: $focus,
                           isListening: !isCompassOpen)
        case .angles(let streams):
            CamAnglePlayer(streams: streams, name: shown.displayName,
                           focus: $focus, isListening: !isCompassOpen)
        case .handoff(let whyNoStream):
            CamHandoff(cam: shown, whyNoStream: whyNoStream)
        }
    }

    /// A still has nothing focusable of its own, so without this the corner's
    /// compass would sit focused — lit up white — for the whole time a rider
    /// watches the picture.
    private var stillGlass: some View {
        Button {} label: {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(BareButton())
        .focusEffectDisabled()
        .focused($focus, equals: .picture)
        .disabled(isCompassOpen)
        .onMoveCommand { direction in
            if direction == .up { focus = .compass }
        }
    }

    /// Resolve where the compass has walked to, as a press on the grid would.
    ///
    /// Keyed on `here`, so a second press while the first is still resolving
    /// cancels the first rather than racing it — the picture that arrives is
    /// always the camera the compass is standing on.
    private func arrive() async {
        guard here.id != shown.id else {
            isResolving = false
            return
        }
        isResolving = CamRoute.needsRoundTrip(here, playsYouTube: playsYouTube)
        let next = await CamRoute.resolve(here, playsYouTube: playsYouTube)
        guard !Task.isCancelled else { return }
        route = next
        shown = here
        isResolving = false
    }

    /// Whether there is a picture for Back to return to — everything but a
    /// code for the phone.
    private var hasPicture: Bool {
        if case .handoff = route { return false }
        return true
    }

    /// Back to the picture when the compass closes. On the next turn, because
    /// the glass is re-enabled by the same change and focus cannot land on a
    /// view that is still disabled. A code for the phone has no picture to go
    /// back to; focus stays where it is.
    private func returnToPicture() {
        if case .handoff = route { return }
        Task { @MainActor in focus = .picture }
    }
}

/// Over the old picture while the next one is found, naming where it is going.
private struct Stepping: View {

    let name: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(name)
                .font(.system(size: 32, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 50)
        .padding(.vertical, 36)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

// MARK: - The corner

/// Two small buttons in the top right: the compass, and everything else.
///
/// The compass used to be a panel of four arrows parked at the bottom right
/// of every camera for the whole session, over the water. Now it is one
/// glyph until it is pressed. Pressed, it opens into four arms that each name
/// the camera they lead to, and the D-pad walks the coast; Select or Menu
/// folds it away again.
///
/// **Every camera is a destination**, not only the ones this box can play by
/// itself. The stage resolves wherever a step lands exactly as the grid
/// would, and a camera that turns out to be a code for the phone is still a
/// place on the coast — the chain carries on from there. The compass used to
/// skip them, and on most of the coast that skipped most of the cameras.
///
/// Every arm names where it goes before it is pressed. On a television that is
/// not a nicety — a press that turns out to lead nowhere costs a rider their
/// place in the only thing on screen, and there is no cheap way back.
struct CamCorner: View {

    let here: SpotGuideStore.GuideResource
    @Binding var isOpen: Bool
    var focus: FocusState<CamStage.Focus?>.Binding
    /// False on a code for the phone, which has no picture to hand Back to.
    var hasPicture = true
    let onPick: (SpotGuideStore.GuideResource) -> Void
    let onSource: () -> Void
    let onReport: () -> Void

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVUnits.self) private var units

    @State private var neighbours: [CamCompass.Direction: SpotGuideStore.GuideResource] = [:]
    @State private var isLoading = true

    private var isOnCompass: Bool { focus.wrappedValue == .compass }
    private var isOnMore: Bool { focus.wrappedValue == .more }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            compass
            // Hidden while the compass is open, so Right means east and never
            // "the button beside it".
            if !isOpen { more }
        }
        // Re-read from wherever the rider has walked to, which is what makes
        // this a chain rather than four readings taken at the start.
        .task(id: here.id) { await load() }
    }

    /// One button whether folded or open, so opening it never moves focus.
    private var compass: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
        } label: {
            if isOpen {
                rose
            } else {
                glyph("arrow.up.and.down.and.arrow.left.and.right", isFocused: isOnCompass)
            }
        }
        .buttonStyle(BareButton())
        .focusEffectDisabled()
        .focused(focus, equals: .compass)
        .onExitCommand(perform: back)
        .onKeyPress(.escape, action: escape)
        .onMoveCommand { direction in
            if isOpen {
                guard !isLoading,
                      let step = Self.compass(for: direction),
                      let destination = neighbours[step] else { return }
                onPick(destination)
            } else if direction == .down {
                focus.wrappedValue = .picture
            } else if direction == .right {
                focus.wrappedValue = .more
            }
        }
        .accessibilityLabel(isOpen ? "Close the camera compass" : "Next camera along the coast")
    }

    private var more: some View {
        Menu {
            Button(action: onSource) {
                Label("Show QR code for the source", systemImage: "qrcode")
            }
            Button(action: onReport) {
                Label("Report this camera", systemImage: "exclamationmark.bubble")
            }
        } label: {
            glyph("ellipsis", isFocused: isOnMore)
        }
        .menuStyle(.button)
        .buttonStyle(BareButton())
        .focusEffectDisabled()
        .focused(focus, equals: .more)
        .onExitCommand(perform: back)
        .onKeyPress(.escape, action: escape)
        .accessibilityLabel("More options for \(here.displayName)")
    }

    /// Back, one layer at a time, heard on whichever corner button has focus.
    ///
    /// An open compass folds. A folded corner hands the remote back to the
    /// picture. Only from the picture does Back leave the camera. A rider
    /// walking the coast pressed Back with the corner lit and landed on the
    /// grid, when what they meant was "stop navigating, let me watch".
    ///
    /// Nil on a code for the phone, where there is no picture to return to:
    /// then Back passes up and leaves, rather than becoming a dead key.
    private var back: (() -> Void)? {
        if isOpen {
            return { withAnimation(.easeOut(duration: 0.18)) { isOpen = false } }
        }
        guard hasPicture else { return nil }
        return { focus.wrappedValue = .picture }
    }

    /// The same `back`, for Esc on a keyboard.
    ///
    /// The remote's Menu arrives as a press `onExitCommand` hears; Esc on the
    /// Mac keyboard in the simulator — or on a keyboard paired with a real
    /// box — arrives as a *key*, which `onExitCommand` never sees. Unheard,
    /// it falls through to UIKit's own Escape, which dismisses the whole
    /// cover: Esc with the compass open went straight to the grid. Ignored
    /// where `back` is nil, so Esc still leaves from a code for the phone.
    private func escape() -> KeyPress.Result {
        guard let back else { return .ignored }
        back()
        return .handled
    }

    private func glyph(_ symbol: String, isFocused: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: 62, height: 62)
            // A faint disc rather than a material: over a black frame, or
            // the black of a code-for-the-phone screen, a material is
            // invisible and the glyph floats with nothing to say it presses.
            .background(isFocused ? Color.white : Color.white.opacity(0.16), in: Circle())
            // Quiet until it is wanted: a corner of the picture, not a
            // control panel sitting over the water.
            .opacity(isFocused ? 1 : 0.7)
            .scaleEffect(isFocused ? 1.12 : 1)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var rose: some View {
        VStack(spacing: 10) {
            arm(.north)
            HStack(spacing: 10) {
                arm(.west)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, height: 62)
                arm(.east)
            }
            arm(.south)

            Group {
                if isLoading {
                    ProgressView()
                } else if neighbours.isEmpty {
                    Text("No other cameras near here")
                } else {
                    Text("Menu or Select to close")
                }
            }
            .font(.system(size: 19))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(22)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(.white.opacity(isOnCompass ? 0.9 : 0.3), lineWidth: 4)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func arm(_ direction: CamCompass.Direction) -> some View {
        let destination = neighbours[direction]
        VStack(spacing: 3) {
            Image(systemName: direction.symbol)
                .font(.system(size: 24, weight: .semibold))
            if let destination {
                Text(destination.displayName)
                    .font(.system(size: 19, weight: .medium))
                    .lineLimit(1)
                // Measured from the camera on screen, not from wherever the
                // list was searched — `CamCompass` re-measures every hop.
                Text(Format.distance(destination.metres, unit: units.preferences.distance))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 230)
        .padding(.vertical, 10)
        .background(.white.opacity(destination == nil ? 0.05 : 0.16),
                    in: RoundedRectangle(cornerRadius: 14))
        .opacity(destination == nil ? 0.4 : 1)
    }

    private static func compass(for direction: MoveCommandDirection) -> CamCompass.Direction? {
        switch direction {
        case .up: .north
        case .down: .south
        case .left: .west
        case .right: .east
        @unknown default: nil
        }
    }

    private func load() async {
        isLoading = true
        let pool = await guide.nearbyResources(near: here.coordinate)
        neighbours = CamCompass.neighbours(from: here.coordinate, among: pool,
                                           excluding: [here.id])
        isLoading = false
    }
}

/// Draws the label and nothing else — no platter, no lift. The corner's
/// buttons draw their own focused look, and the still's glass must draw none.
private struct BareButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
