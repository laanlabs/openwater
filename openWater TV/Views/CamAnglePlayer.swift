import AVKit
import Combine
import OpenWaterSpots
import SwiftUI

/// A camera with more than one angle, and the arrows to move between them.
///
/// Montauk Point Lighthouse publishes five — Northside, Rips, Alamo,
/// Southside, Frontgate — and an EarthCam location page carries every camera
/// at it. Playing only the first would throw the rest away, and on a
/// television the list is the point: this is somebody on a sofa looking at
/// the water from several sides, which is a thing a phone is bad at.
///
/// **No system transport bar.** `VideoPlayer` brings tvOS's own controls,
/// and those eat the D-pad — left and right would scrub rather than change
/// camera. So the picture is a bare `AVPlayerLayer` and every key is this
/// screen's own. Nothing is lost: there is nothing to scrub on a live camera,
/// and the recorded clips loop.
struct CamAnglePlayer: View {

    let streams: [WebcamStream.Stream]
    let name: String

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var player: AVQueuePlayer?
    @State private var isShowingChrome = true
    /// The current angle's item reported failure — see `start`.
    @State private var didFail = false
    @FocusState private var isDriving: Bool

    private var current: WebcamStream.Stream { streams[min(index, streams.count - 1)] }

    var body: some View {
        ZStack {
            Color.black
            PlayerLayer(player: player)
            keys
            if didFail { StreamFailed(name: current.label.isEmpty ? name : current.label) }
            if isShowingChrome { chrome }
        }
        .ignoresSafeArea()
        // Menu leaves, said here rather than trusted to the cover: the
        // full-screen button below owns every other key on this screen, and
        // a screen that owns the remote has to give Menu back itself.
        .onExitCommand { dismiss() }
        .onAppear { isDriving = true }
        .task(id: index) { await start() }
        // The chrome goes after a few seconds so the water has the screen,
        // and any key brings it back — the convention every television player
        // already taught the room.
        .task(id: chromeKey) {
            isShowingChrome = true
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            isShowingChrome = false
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// Bumped by anything that should re-show the chrome and restart its
    /// countdown.
    private var chromeKey: String { "\(index)|\(isDriving)" }

    private func start() async {
        player?.pause()
        didFail = false
        let item = AVPlayerItem(url: current.url)
        let queue = AVQueuePlayer(items: [item])
        // A cam has no sound worth hearing and a living room has somebody
        // else in it.
        queue.isMuted = true
        queue.play()
        player = queue
        // Wait for the item's verdict. This runs inside the `task(id: index)`
        // that called it, so stepping to another angle retires the watch
        // along with the player it was watching.
        for await status in item.publisher(for: \.status).values {
            if status == .failed { didFail = true; return }
            if status == .readyToPlay { return }
        }
    }

    /// The whole glass, listening.
    ///
    /// A button rather than a bare `focusable`, because Select has to be
    /// heard too — and with `NoChrome` it draws nothing, which a focused
    /// full-screen button otherwise very much does.
    private var keys: some View {
        Button { isShowingChrome.toggle() } label: {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(NoChrome())
        .focusEffectDisabled()
        .focused($isDriving)
        .onMoveCommand { direction in
            switch direction {
            case .left:  step(-1)
            case .right: step(1)
            default:     isShowingChrome = true
            }
        }
    }

    private func step(_ delta: Int) {
        guard streams.count > 1 else {
            isShowingChrome = true
            return
        }
        index = (index + delta + streams.count) % streams.count
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.backward")
                    Text("Menu")
                }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                Text(name)
                    .font(.system(size: 32, weight: .semibold))
                Spacer()
                if current.isClip {
                    // Said plainly: these are the operator's recordings on a
                    // loop, not a live picture, and a rider watching for a
                    // set to come through should know which they have.
                    Label("Recorded loop", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 50)

            Spacer()

            if streams.count > 1 {
                HStack(spacing: 26) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 40))
                    Text(current.label)
                        .font(.system(size: 34, weight: .semibold))
                        .frame(minWidth: 300)
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 40))
                    Text("\(index + 1) of \(streams.count)")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 60)
            } else {
                Text(current.label)
                    .font(.system(size: 30, weight: .medium))
                    .padding(.horizontal, 34)
                    .padding(.vertical, 16)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 60)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: isShowingChrome)
        .allowsHitTesting(false)
    }
}

/// `AVPlayerLayer` with no controls at all, so the D-pad belongs to the
/// screen around it rather than to a transport bar.
private struct PlayerLayer: UIViewRepresentable {

    let player: AVPlayer?

    func makeUIView(context: Context) -> LayerView { LayerView() }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Draws the label and nothing else — no focus background, no lift. The same
/// need the wind map's driving surface has, for the same reason: a
/// full-screen button wearing tvOS's focused appearance is a white panel over
/// the whole picture.
private struct NoChrome: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
