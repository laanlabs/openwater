import Charts
import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The water itself: which way it is running here, and when it turns.
///
/// The phone's flow map, on a television. Wind is the question this app opens
/// with, but on a tidal coast the current is the one that decides whether a
/// crossing is a glide or an afternoon of going nowhere — and unlike wind it
/// is invisible from the beach, so a picture of it is worth more here than
/// almost anything else.
///
/// The wash is the same `WindWashModel` the wind map draws, asked for
/// `.currents` instead: the same 7×9 field, the same quads, and the same
/// comets streaming over it — which for water is not decoration but the whole
/// point, because a still arrow says a direction and a moving one says a
/// rate. The current wash is cut to the coastline, so it never paints a
/// street.
///
/// Two honesties this screen owes, both the phone's own: the arrows state
/// *toward* rather than the wind convention of *from*, and the source is
/// named — a NOAA station replaces the model outright rather than blending
/// with it, because they are different physics with different answers.
struct CurrentFlowScreen: View {

    let here: Geo.Coordinate
    let placeName: String

    @State private var wash = WindWashModel()
    @State private var outlook: CurrentsOutlook?
    @State private var isLoading = true
    @State private var visible: MKCoordinateRegion?
    @State private var mapWidth: CGFloat = 1920

    @Environment(\.displayScale) private var displayScale
    @Namespace private var page

    /// Tight enough that the field is about this bay rather than this coast —
    /// current is a local argument in a way wind is not.
    private static let span = 0.35

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
            span: MKCoordinateSpan(latitudeDelta: Self.span, longitudeDelta: Self.span))
    }

    private var now: CurrentsOutlook.Hour? { outlook?.hour(at: nil) }

    var body: some View {
        // The map, full screen, and Menu to leave.
        //
        // This was a scrolling page with the map a third of the way down it,
        // 520 points tall, under a headline card — so the thing the screen is
        // named for had to be scrolled to on a device with no scrolling, only
        // focus. Everything else here is a caption on the map rather than a
        // section beside it, so the map takes the glass and the words sit on
        // top of it.
        ZStack(alignment: .topLeading) {
            flowMap
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(28)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 28))
                    .padding(.leading, 90)
                    .padding(.top, 40)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.large)
                        .padding(.leading, 90)
                        .padding(.bottom, 60)
                } else if let outlook, !outlook.isEmpty, !upcoming.isEmpty {
                    turnsStrip
                } else if outlook?.isEmpty ?? false {
                    Text("No current model for this point. Open water away from a tidal coast often has none.")
                        .font(.system(size: 28))
                        .padding(24)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))
                        .padding(.leading, 90)
                        .padding(.bottom, 60)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.white)
        .menuBackHint()
        .task {
            isLoading = true
            outlook = await Currents.outlook(at: here)
            isLoading = false
        }
    }

    /// The turns, along the bottom rather than down the page.
    ///
    /// Horizontal because they are a sequence in time and there are only ever
    /// a handful worth naming — and because a column of them here would be
    /// the scrolling this screen was rebuilt to get rid of.
    private var turnsStrip: some View {
        HStack(spacing: 20) {
            ForEach(upcoming.prefix(5)) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline(event))
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                    Text(event.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            }
            Spacer()
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 56)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current")
                .font(.system(size: 56, weight: .bold))
            Text(placeName)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            if let now, let speed = now.speedKn {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    if let set = now.directionDeg {
                        // No `+180`. A current states where it is *going*,
                        // which is the one place in this app the wind habit
                        // of flipping the arrow would reverse every river.
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 40))
                            .rotationEffect(.degrees(set))
                            .foregroundStyle(CurrentPalette.color(for: speed))
                    }
                    Text(String(format: "%.1f", speed))
                        .font(.system(size: 110, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("kn")
                            .font(.system(size: 34, weight: .semibold))
                        if let set = now.directionDeg {
                            Text("setting \(Format.cardinal(set))")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            } else if let next = outlook?.nextEvent {
                // A subordinate NOAA station publishes only the turns — no
                // hourly curve at all — so there is no "now" to print. The
                // next turn is the honest headline in that case, and far
                // better than the blank this screen used to show.
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Image(systemName: next.kind == .slack
                          ? "pause.circle.fill" : "arrow.up.right.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline(next))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                        Text(next.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.top, 6)
                Text("This station predicts the turns rather than an hourly rate.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func headline(_ event: CurrentsOutlook.Event) -> String {
        let name = switch event.kind {
        case .maxFlood: "Max flood"
        case .maxEbb: "Max ebb"
        case .slack: "Slack water"
        }
        guard let speed = event.speedKn else { return "Next: \(name)" }
        return String(format: "Next: %@ %.1f kn", name, speed)
    }

    /// The field, drawn the way the wind map draws its own.
    private var flowMap: some View {
        let cells = wash.cells
        let field = wash.field
        return MapReader { proxy in
            Map(initialPosition: .region(region), interactionModes: []) {
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.coordinates)
                        .foregroundStyle(cell.color)
                }
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: here.latitude, longitude: here.longitude)) {
                    Circle()
                        .fill(Color.black.opacity(0.75))
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 22, height: 22)
                }
                .annotationTitles(.hidden)
            }
            .focusable(false)
            .mapStyle(.standard(elevation: .flat, emphasis: .muted,
                                pointsOfInterest: .excludingAll))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                mapWidth = width
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visible = context.region
                wash.viewSettled(on: context.region, layer: .currents,
                                 widthPoints: mapWidth, displayScale: displayScale)
            }
            .overlay {
                if let field { WashParticleLayer(field: field, proxy: proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if wash.isBusy {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(WashLayer.currents.loadingLabel)
                    }
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The next few turns. Station predictions name these; the model curve
    /// never carries them, so the strip simply is not there for a modelled
    /// point rather than inventing peaks from a curve.
    private var upcoming: [CurrentsOutlook.Event] {
        Array((outlook?.events ?? []).filter { $0.at > Date() }.prefix(5))
    }
}
