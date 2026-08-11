import MapKit
import OpenWaterCore
import SwiftUI

/// The wind as a field, not a number.
///
/// A single forecast says what the wind is here; a flow map says what it is
/// doing — the sea breeze filling from the south shore, the gradient dying
/// in the lee of the hills, the line where two of them argue. This is that
/// view from the same free model the rest of the sheet reads: a grid of
/// arrows over the water, coloured by strength, with a scrubber through the
/// next day.
///
/// Deliberately arrows at ~10 km spacing rather than smeared rasters and
/// particle trails: that is the resolution the model actually computes, and
/// drawing detail between grid points would be inventing wind. One batched
/// request fetches the whole day for every arrow at once.
struct FlowMapScreen: View {

    let title: String
    let coordinate: Geo.Coordinate

    @State private var hours: [Date] = []
    @State private var grid: [GridPoint] = []
    @State private var hourIndex: Double = 0
    @State private var isLoading = true

    struct GridPoint: Identifiable {
        let id: Int
        let coordinate: Geo.Coordinate
        /// Knots and degrees-from, aligned to `hours`.
        let speeds: [Double?]
        let directions: [Double?]
    }

    private var hour: Int { Int(hourIndex.rounded()) }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate.clCoordinate,
            latitudinalMeters: Self.spanMetres * 1.15,
            longitudinalMeters: Self.spanMetres * 1.15
        ))) {
            Annotation("", coordinate: coordinate.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            .annotationTitles(.hidden)

            ForEach(grid) { point in
                Annotation("", coordinate: point.coordinate.clCoordinate) {
                    if let speed = point.speeds[safe: hour] ?? nil,
                       let direction = point.directions[safe: hour] ?? nil {
                        FlowArrow(speedKn: speed, directionFromDeg: direction)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .navigationTitle("Flow map")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Flow map")
        .safeAreaInset(edge: .bottom) { controls }
        .overlay {
            if isLoading {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await load() }
    }

    // MARK: The scrubber

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(hourLabel)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                if hour == 0 {
                    Text("now")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
                Spacer()
                legend
            }

            if hours.count > 1 {
                Slider(value: $hourIndex, in: 0...Double(hours.count - 1), step: 1)
            }

            Text("Open-Meteo's blend, arrows at the ~10 km grid the model actually "
                 + "computes — drawing wind between them would be inventing it. "
                 + "Scrub through the next 24 hours.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var hourLabel: String {
        guard let date = hours[safe: hour] else { return "—" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var legend: some View {
        HStack(spacing: 5) {
            ForEach(Self.legendSteps, id: \.label) { step in
                HStack(spacing: 2) {
                    Circle()
                        .fill(step.colour)
                        .frame(width: 7, height: 7)
                    Text(step.label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let legendSteps: [(label: String, colour: Color)] = [
        ("<8", FlowArrow.colour(for: 5)),
        ("8+", FlowArrow.colour(for: 10)),
        ("12+", FlowArrow.colour(for: 13)),
        ("15+", FlowArrow.colour(for: 17)),
        ("21+", FlowArrow.colour(for: 22)),
    ]

    // MARK: The field

    /// About sixty kilometres of coast — the water a rider would actually
    /// drive along, at a span where ~10 km arrows still read as a field.
    private static let spanMetres: Double = 60_000
    private static let columns = 7
    private static let rows = 9

    private func load() async {
        let coords = gridCoordinates()
        let field = await OpenMeteo.windAlong(coords, hours: 24)
        // The time axis from the densest answer — cells the model has no
        // data for simply keep their nils.
        let axis = field.max(by: { $0.count < $1.count })?.map(\.date) ?? []
        hours = axis
        grid = coords.indices.compactMap { index -> GridPoint? in
            guard let rows = field[safe: index], !rows.isEmpty else { return nil }
            var speeds = [Double?](repeating: nil, count: axis.count)
            var directions = [Double?](repeating: nil, count: axis.count)
            for row in rows {
                guard let slot = axis.firstIndex(of: row.date) else { continue }
                speeds[slot] = row.speedKn
                directions[slot] = row.directionDeg
            }
            return GridPoint(id: index, coordinate: coords[index],
                             speeds: speeds, directions: directions)
        }
        withAnimation(.easeOut(duration: 0.2)) { isLoading = false }
    }

    private func gridCoordinates() -> [Geo.Coordinate] {
        let latSpan = Self.spanMetres / 110_574
        let lonSpan = Self.spanMetres / (111_320 * cos(coordinate.latitude * .pi / 180))
        var out: [Geo.Coordinate] = []
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                out.append(Geo.Coordinate(
                    latitude: coordinate.latitude - latSpan / 2
                        + latSpan * Double(row) / Double(Self.rows - 1),
                    longitude: coordinate.longitude - lonSpan / 2
                        + lonSpan * Double(column) / Double(Self.columns - 1)
                ))
            }
        }
        return out
    }
}

/// One arrow of the field: pointing the way the wind blows, coloured by how
/// hard, with the knots underneath once there is anything worth reading.
private struct FlowArrow: View {

    let speedKn: Double
    let directionFromDeg: Double

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: speedKn < 2 ? "circle.dotted" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .rotationEffect(.degrees(speedKn < 2 ? 0 : directionFromDeg + 180))
            if speedKn >= 2 {
                Text("\(Int(speedKn.rounded()))")
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Self.colour(for: speedKn))
        .shadow(color: .white.opacity(0.8), radius: 1.5)
    }

    /// The ramp, on the app's own thresholds: grey until it matters, the
    /// chart blues through the working range, the firing threshold at 15,
    /// and the strong end in the colours the strip already taught.
    static func colour(for kn: Double) -> Color {
        switch kn {
        case ..<8: Color(.systemGray)
        case ..<12: .teal
        case ..<15: Color.accentColor
        case ..<21: .orange
        default: .pink
        }
    }
}
