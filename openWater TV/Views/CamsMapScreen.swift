import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The same cameras, where they actually are.
///
/// The grid answers "which of these can I watch"; this answers "what is at the
/// end of the beach I am thinking about", which is what somebody staring at a
/// coastline is usually asking. It opens over the grid rather than replacing
/// it, so Menu means what it means everywhere else on this box.
struct CamsMapScreen: View {

    let cams: [SpotGuideStore.GuideResource]

    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic

    /// What the map is actually showing, so pan and zoom have something to
    /// move. Nil until the first frame has been set.
    @State private var region: MKCoordinateRegion?

    /// Whether the remote is driving the map rather than working the bar.
    @State private var isDriving = false

    /// Which camera the arrows are on.
    ///
    /// An ordered index rather than letting the focus engine walk the pins by
    /// geometry. They cluster hard — a dozen inside a mile at Montauk, which
    /// is exactly where the good water is — and spatial focus in a cluster
    /// lands somewhere a rider did not aim. Stepping a list always goes where
    /// the press said it would, and the order is the grid's own: playable
    /// first, then nearest.
    @State private var index = 0

    private enum Focus: Hashable { case map, bar }
    @FocusState private var focus: Focus?

    /// The wind map's steps, on purpose. Two maps in one app that drive
    /// differently is a thing a rider has to learn twice.
    private static let panStep = 0.08
    private static let tightestSpan = 0.02
    private static let widestSpan = 90.0

    private var current: SpotGuideStore.GuideResource? {
        cams.indices.contains(index) ? cams[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Map(position: $camera, interactionModes: []) {
                ForEach(Array(cams.enumerated()), id: \.element.id) { position, cam in
                    Annotation(cam.displayName,
                               coordinate: CLLocationCoordinate2D(
                                   latitude: cam.coordinate.latitude,
                                   longitude: cam.coordinate.longitude)) {
                        CamCard(cam: cam, style: .pin,
                                isStepped: !isDriving && position == index)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                pointsOfInterest: .excludingAll))
            .onMapCameraChange { context in region = context.region }
            .ignoresSafeArea()
            if isDriving { drivingSurface }
        }
        .onAppear(perform: frame)
        .safeAreaInset(edge: .bottom) { bar }
        .menuBackHint()
        .onExitCommand { dismiss() }
    }

    /// The map's turn with the remote.
    ///
    /// A focusable button covering the glass, because on tvOS only a *button*
    /// hears Select. Its four directions are intercepted rather than moving
    /// focus — which is what keeps a pan upward out of the tab bar — Select
    /// zooms in, Play/Pause zooms out, and Menu hands the remote back to the
    /// bar rather than closing the map, because a rider deep in a pan means
    /// "stop panning" by it.
    private var drivingSurface: some View {
        Button { zoom(by: 0.6) } label: {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(NoStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .map)
        .defaultFocus($focus, .map)
        .onMoveCommand { direction in
            switch direction {
            case .up:    pan(dx: 0, dy: Self.panStep)
            case .down:  pan(dx: 0, dy: -Self.panStep)
            case .left:  pan(dx: -Self.panStep, dy: 0)
            case .right: pan(dx: Self.panStep, dy: 0)
            @unknown default: break
            }
        }
        .onPlayPauseCommand { zoom(by: 1 / 0.6) }
        .onExitCommand { isDriving = false; focus = .bar }
    }

    /// Step the cameras, or take the map. One bar, because they are the same
    /// question at two scales: which camera, and which piece of coast.
    ///
    /// The name in the middle is the button that opens it — a `CamCard` in its
    /// bar form, so watching from here goes through exactly the same resolving
    /// and the same routes as pressing a card in the grid.
    private var bar: some View {
        HStack(spacing: 24) {
            Button { step(by: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 28, weight: .semibold))
            }
            .disabled(cams.count < 2)

            VStack(spacing: 4) {
                if let current {
                    CamCard(cam: current, style: .bar)
                }
                Text(cams.isEmpty ? "No cameras" : "\(index + 1) of \(cams.count)")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 640)

            Button { step(by: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 28, weight: .semibold))
            }
            .disabled(cams.count < 2)

            Button {
                isDriving = true
                focus = .map
            } label: {
                Label("Pan & zoom", systemImage: "dpad")
                    .font(.system(size: 24, weight: .medium))
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
        .background(.black.opacity(0.8), in: Capsule())
        .focusSection()
        .padding(.bottom, 30)
        // Gone while driving rather than merely dimmed: a focusable bar under
        // a pan is somewhere for Down to land instead of moving the map.
        .opacity(isDriving ? 0 : 1)
        .allowsHitTesting(!isDriving)
    }

    /// Ordered, wrapping, and it carries the map with it — a camera named in a
    /// bar while its pin is off the edge of the screen is a camera nobody can
    /// see. The rider's own zoom is kept; only the centre moves.
    private func step(by delta: Int) {
        guard !cams.isEmpty else { return }
        index = (index + delta + cams.count) % cams.count
        guard let cam = current else { return }
        let span = region?.span ?? MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: cam.coordinate.latitude,
                                               longitude: cam.coordinate.longitude),
                span: span))
        }
    }

    /// Pan by a fraction of what is on screen, so one press moves the same
    /// proportion of the view at every zoom.
    private func pan(dx: Double, dy: Double) {
        guard let region else { return }
        var moved = region
        moved.center.latitude = min(max(region.center.latitude
                                        + region.span.latitudeDelta * dy, -85), 85)
        moved.center.longitude = region.center.longitude + region.span.longitudeDelta * dx
        camera = .region(moved)
    }

    private func zoom(by factor: Double) {
        guard let region else { return }
        let latitudeDelta = min(max(region.span.latitudeDelta * factor,
                                    Self.tightestSpan), Self.widestSpan)
        // Scale longitude by what latitude actually did, so a clamped zoom
        // does not squash the aspect the map is drawn at.
        let applied = latitudeDelta / region.span.latitudeDelta
        camera = .region(MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta,
                                   longitudeDelta: region.span.longitudeDelta * applied)))
    }

    /// Open on the cameras themselves rather than on a fixed radius: the
    /// nearest six may all be in one bay, and a box drawn round the search
    /// radius would put them in a huddle in the middle of the screen.
    private func frame() {
        let points = cams.map(\.coordinate)
        guard let first = points.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        let centre = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // A floor on the span, or a single camera zooms to the building it is
        // bolted to; the margin keeps the outermost pins off the edge, where
        // a pin would be half a glyph.
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.15),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, 0.15))
        let framed = MKCoordinateRegion(center: centre, span: span)
        camera = .region(framed)
        region = framed
    }
}
