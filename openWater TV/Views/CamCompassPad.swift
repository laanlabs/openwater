import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The joystick you go into, to walk the coast camera by camera.
///
/// The arrows at the foot of the angle player step between *angles of one
/// camera*, and they keep doing exactly that — Montauk's five sides are a
/// different journey from Montauk to Hither Hills. So this is a separate
/// control with its own focus: press down from the picture to enter it, and
/// then the D-pad is a compass rather than a camera selector. Select gives the
/// picture back.
///
/// Every arm names where it goes before it is pressed. On a television that is
/// not a nicety — a press that turns out to lead nowhere costs a rider their
/// place in the only thing on screen, and there is no cheap way back.
struct CamJoystick: View {

    let origin: SpotGuideStore.GuideResource
    let onPick: (SpotGuideStore.GuideResource) -> Void
    /// Where focus goes when the rider presses Select. Nil where there is
    /// nothing to go back to, as on a single-stream player.
    var onExit: (() -> Void)?

    /// Owned by the screen around it, which needs to hand focus over — a
    /// `@FocusState` declared here could not be reached from outside.
    @FocusState.Binding var isDriving: Bool

    @Environment(SpotGuideStore.self) private var guide

    @State private var neighbours: [CamCompass.Direction: SpotGuideStore.GuideResource] = [:]
    @State private var isLoading = true

    var body: some View {
        Button {
            onExit?()
        } label: {
            rose
        }
        .buttonStyle(.plain)
        .focused($isDriving)
        .onMoveCommand { direction in
            guard let step = Self.compass(for: direction),
                  let destination = neighbours[step] else { return }
            onPick(destination)
        }
        // Re-read from wherever the rider has walked to, which is what makes
        // this a chain rather than four readings taken at the start.
        .task(id: origin.id) { await load() }
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
        // Only what this box can open. tvOS has no web view, so a camera the
        // guide holds no stream or still for is a QR code for the phone — and
        // stepping from a playing camera onto a QR code is a dead end, not a
        // step. The phone's compass has no such filter, because Safari can
        // open anything.
        let pool = await guide.nearbyResources(near: origin.coordinate)
            .filter { $0.playback != nil }
        neighbours = CamCompass.neighbours(from: origin.coordinate, among: pool,
                                           excluding: [origin.id])
        isLoading = false
    }

    private var rose: some View {
        VStack(spacing: 10) {
            arm(.north)
            HStack(spacing: 10) {
                arm(.west)
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, height: 70)
                arm(.east)
            }
            arm(.south)

            if isLoading {
                ProgressView()
            } else if neighbours.isEmpty {
                Text("No other cameras this box can play near here")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            } else if isDriving {
                Text("Select for the picture")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(.white.opacity(isDriving ? 0.9 : 0), lineWidth: 4)
        }
        // Small and quiet until it is entered, so it is not a panel sitting
        // over the water for the whole session.
        .scaleEffect(isDriving ? 1 : 0.82)
        .opacity(isDriving ? 1 : 0.55)
        .animation(.easeOut(duration: 0.18), value: isDriving)
    }

    @ViewBuilder
    private func arm(_ direction: CamCompass.Direction) -> some View {
        let destination = neighbours[direction]
        VStack(spacing: 2) {
            Image(systemName: direction.symbol)
                .font(.system(size: 26, weight: .semibold))
            if let destination, isDriving {
                Text(destination.displayName)
                    .font(.system(size: 19))
                    .lineLimit(1)
            }
        }
        .frame(width: isDriving ? 200 : 70)
        .padding(.vertical, 10)
        .background(.white.opacity(destination == nil ? 0.06 : 0.18),
                    in: RoundedRectangle(cornerRadius: 14))
        .opacity(destination == nil ? 0.4 : 1)
    }
}

/// Hosts a camera screen and lets the joystick replace it with another.
///
/// The compass only ever offers cameras the guide already has a stream or a
/// still for, because those are the ones this box can open — everything else
/// on tvOS is a QR code for the phone, and landing on one of those from inside
/// a player would be a dead end rather than a step. So a destination is always
/// a `CamPlayer`, whatever the screen it was reached from.
struct CamStage: View {

    enum Start {
        case play(URL, isStill: Bool)
        case angles([WebcamStream.Stream])
    }

    let start: Start
    let cam: SpotGuideStore.GuideResource

    /// Where the joystick has walked to, if anywhere.
    @State private var stepped: SpotGuideStore.GuideResource?

    private var here: SpotGuideStore.GuideResource { stepped ?? cam }

    var body: some View {
        Group {
            if let stepped, let playback = stepped.playback {
                switch playback {
                case .stream(let url):
                    CamPlayer(url: url, isStill: false, name: stepped.displayName,
                              here: here, onStep: step)
                    .id(stepped.id)
                case .still(let url):
                    CamPlayer(url: url, isStill: true, name: stepped.displayName,
                              here: here, onStep: step)
                    .id(stepped.id)
                }
            } else {
                switch start {
                case let .play(url, isStill):
                    CamPlayer(url: url, isStill: isStill, name: cam.displayName,
                              here: here, onStep: step)
                case let .angles(streams):
                    CamAnglePlayer(streams: streams, name: cam.displayName,
                                   here: here, onStep: step)
                }
            }
        }
    }

    private func step(_ destination: SpotGuideStore.GuideResource) {
        stepped = destination
    }
}
