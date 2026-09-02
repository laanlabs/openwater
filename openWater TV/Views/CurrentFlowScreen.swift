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
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                ScrollStop { flowMap }
                if isLoading {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let outlook, !outlook.isEmpty {
                    if !outlook.hours.isEmpty { ScrollStop { chart } }
                    ForEach(upcoming) { event in
                        ScrollStop { TurnRow(event: event) }
                    }
                    ScrollStop { provenance(outlook) }
                } else {
                    ScrollStop {
                        Text("No current model for this point. Open water away from a tidal coast often has none.")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .focusScope(page)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .menuBackHint()
        .task {
            isLoading = true
            outlook = await Currents.outlook(at: here)
            isLoading = false
        }
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
            .frame(height: 520)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    /// The day's rate. Magnitude only — the direction is the arrows' job, and
    /// a signed curve would need a convention about which way is positive
    /// that no two harbours agree on.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THROUGH THE DAY")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Chart {
                ForEach(dayHours) { hour in
                    if let speed = hour.speedKn {
                        AreaMark(x: .value("Time", hour.at), y: .value("Knots", speed))
                            .foregroundStyle(.linearGradient(
                                colors: [Color.cyan.opacity(0.5), Color.cyan.opacity(0.04)],
                                startPoint: .top, endPoint: .bottom))
                    }
                }
                ForEach(dayHours) { hour in
                    if let speed = hour.speedKn {
                        LineMark(x: .value("Time", hour.at), y: .value("Knots", speed))
                            .foregroundStyle(.white)
                            .lineStyle(StrokeStyle(lineWidth: 4))
                    }
                }
                RuleMark(x: .value("Now", Date()))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .annotation(position: .top) {
                        Text("Now")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel {
                        if let knots = value.as(Double.self) {
                            Text(String(format: "%.1f", knots))
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour())
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 320)
        }
    }

    /// A day and a half — far enough to plan tomorrow morning's crossing.
    private var dayHours: [CurrentsOutlook.Hour] {
        let end = Date().addingTimeInterval(36 * 3600)
        return (outlook?.hours ?? []).filter {
            $0.at >= Date().addingTimeInterval(-3 * 3600) && $0.at <= end
        }
    }

    /// The next few turns. Station predictions name these; the model curve
    /// never carries them, so this section simply is not there for a modelled
    /// point rather than inventing peaks from a curve.
    private var upcoming: [CurrentsOutlook.Event] {
        Array((outlook?.events ?? []).filter { $0.at > Date() }.prefix(5))
    }

    /// Which authority is answering. Never blended, and said out loud for the
    /// reason the tide screen says its datum: a station and a model disagree,
    /// and a rider who knows the difference wants to know which this is.
    private func provenance(_ outlook: CurrentsOutlook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHERE THESE NUMBERS COME FROM")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            switch outlook.source {
            case .station(let station):
                Text("\(station.name), \(Format.distance(station.metres, unit: UnitPreferences.forThisDevice.distance)) away — NOAA harmonic predictions. Predicted from harmonics, not measured.")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .model:
                Text("Open-Meteo ocean model. Worldwide and hourly, and a model — a named current station would be more exact; there is not one within range of this point.")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One turn of the water: slack, or a peak and how hard it runs.
private struct TurnRow: View {

    let event: CurrentsOutlook.Event

    private var label: String {
        switch event.kind {
        case .maxFlood: "Max flood"
        case .maxEbb: "Max ebb"
        case .slack: "Slack"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .maxFlood: "arrow.up.right.circle.fill"
        case .maxEbb: "arrow.down.left.circle.fill"
        case .slack: "pause.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(event.kind == .slack ? Color.secondary : Color.cyan)
            Text(label)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 190, alignment: .leading)
            Text(event.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.system(size: 30))
                .monospacedDigit()
            Spacer()
            if let speed = event.speedKn {
                Text(String(format: "%.1f kn", speed))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(event.at, style: .relative)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .trailing)
        }
    }
}
