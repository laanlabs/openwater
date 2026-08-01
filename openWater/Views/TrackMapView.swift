import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// The session map, drawn so it can actually be read.
///
/// A wing session is dozens of passes through the same water. Drawn as one
/// speed-coloured line it is a scribble — every pass sits on top of every other
/// and nothing is distinguishable. Three things fix that, and this view does all
/// three:
///
/// - **Ride state changes how a stretch is drawn**, not just its colour.
///   Flights are thick and opaque, riding is thinner, slow and stopped fade to a
///   faint ghost. That alone separates the signal from the paddling-about.
/// - **Falls get a marker.** They are the events you look for, and a break in a
///   line is not something the eye finds in a tangle.
/// - **Run isolation.** Selecting one run drops every other to a ghost layer.
///   Stepping through runs one at a time is the single biggest legibility win
///   there is, because it removes the overlap entirely.
struct TrackMapView: View {

    let session: Session
    let summary: SessionSummary

    /// Run to isolate. `nil` shows the whole session.
    var selectedRun: Int?

    /// Highlight a specific time range — used to show where a record was set.
    var highlight: ClosedRange<TimeInterval>?

    var showFalls: Bool = true
    var showManeuvers: Bool = false

    /// Only draw stretches at or above this speed, m/s.
    var minimumSpeed: Double = 0

    /// Only draw stretches spent flying.
    var foilingOnly: Bool = false

    /// Which ride states to draw. The point of separating flying from the rest
    /// is that a foil session's track is two different activities on top of
    /// each other, and looking at either one alone is far more readable than
    /// looking at both.
    var foilFilter: FoilFilter = .everything

    /// Draw only up to this elapsed time. Used by the scrubber, so dragging
    /// through the session reveals it in order instead of showing the finished
    /// tangle all at once.
    var partialUpTo: TimeInterval?

    /// Where the scrubber is, marked on the track.
    var playhead: TimeInterval?

    /// The stretch a trim would keep, marked at both ends. Declared after
    /// `playhead` so the call sites read in the order the arguments appear.
    ///
    /// Dragging a handle on a chart tells a rider *when* they are cutting; only
    /// the map tells them *where*, which on a session of forty overlapping
    /// passes is the thing they actually need to see.
    var trimRange: ClosedRange<TimeInterval>?

    /// Which end the finger is on, drawn larger so it is findable in a tangle.
    var activeTrimEdge: TrimEdge?

    /// When true, `trimRange` is the stretch being *cut* rather than kept, so
    /// the track stays whole and the doomed part is struck through instead.
    var trimIsRemoval: Bool = false

    /// Base map. Satellite is worth having on water, where the standard map is
    /// a featureless blue field with nothing to orient by.
    var style: MapStyleOption = .standard

    @State private var camera: MapCameraPosition = .automatic

    public enum TrimEdge { case start, end }

    /// What counts as visible track.
    enum FoilFilter: String, CaseIterable, Identifiable {
        case everything = "Everything"
        case foiling = "On foil"
        case notFoiling = "Off foil"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .everything: "point.topleft.down.to.point.bottomright.curvepath"
            case .foiling: "airplane"
            case .notFoiling: "water.waves"
            }
        }
    }

    var body: some View {
        Map(position: $camera) {
            // Ghost layer first, so the highlighted content draws over it.
            if selectedRun != nil || highlight != nil || foilingOnly
                || foilFilter != .everything || minimumSpeed > 0 || partialUpTo != nil {
                MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                    .stroke(
                        style.isDark ? .white.opacity(0.28) : .gray.opacity(0.22),
                        lineWidth: 2
                    )
            }

            ForEach(visibleSegments) { segment in
                MapPolyline(coordinates: coordinates(for: segment))
                    .stroke(
                        style(for: segment),
                        style: StrokeStyle(
                            lineWidth: lineWidth(for: segment),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            if showFalls {
                ForEach(summary.fallSummary.falls) { fall in
                    Annotation(
                        "Fall",
                        coordinate: fall.coordinate.clCoordinate,
                        anchor: .center
                    ) {
                        FallMarker(fall: fall)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if showManeuvers {
                ForEach(summary.maneuvers) { maneuver in
                    if let coordinate = session.track.points[safe: maneuver.startIndex]?.clCoordinate {
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            ManeuverMarker(maneuver: maneuver)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }

            if let trimRange, trimIsRemoval {
                ForEach(summary.segments) { segment in
                    MapPolyline(coordinates: coordinates(for: segment, clippedTo: trimRange))
                        .stroke(
                            Color.red.opacity(0.55),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [2, 7])
                        )
                }
            }

            if let trimRange {
                if let position = session.track.coordinate(atElapsed: trimRange.lowerBound) {
                    Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                        TrimMarker(isStart: true, isActive: activeTrimEdge == .start)
                    }
                    .annotationTitles(.hidden)
                }
                if let position = session.track.coordinate(atElapsed: trimRange.upperBound) {
                    Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                        TrimMarker(isStart: false, isActive: activeTrimEdge == .end)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let playhead, let position = session.track.coordinate(atElapsed: playhead) {
                Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                    Playhead(
                        speed: session.track.speed[session.track.index(atElapsed: playhead) ?? 0],
                        maxSpeed: summary.maxSpeed
                    )
                }
                .annotationTitles(.hidden)
            }

            if let start = session.track.points.first?.clCoordinate {
                Marker("Start", systemImage: "flag", coordinate: start)
                    .tint(.green)
            }
            if let end = session.track.points.last?.clCoordinate {
                Marker("End", systemImage: "flag.checkered", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(style.mapStyle)
        .onChange(of: selectedRun) { _, _ in frameSelection() }
        .onAppear { frameSelection() }
    }

    // MARK: - Filtering

    private var visibleSegments: [StateSegment] {
        summary.segments.filter { segment in
            if let selectedRun, segment.runIndex != selectedRun { return false }
            if foilingOnly, segment.state != .foiling { return false }
            switch foilFilter {
            case .everything: break
            case .foiling: if segment.state != .foiling { return false }
            case .notFoiling: if segment.state == .foiling { return false }
            }
            if let partialUpTo, segment.startElapsed > partialUpTo { return false }
            if minimumSpeed > 0, segment.maxSpeed < minimumSpeed { return false }
            if let highlight {
                let overlaps = segment.startElapsed <= highlight.upperBound
                    && segment.endElapsed >= highlight.lowerBound
                if !overlaps { return false }
            }
            return true
        }
    }

    /// The part of a segment inside an explicit range — used to draw the
    /// stretch a removal would cut, over the top of the whole track.
    private func coordinates(
        for segment: StateSegment,
        clippedTo range: ClosedRange<TimeInterval>
    ) -> [CLLocationCoordinate2D] {
        guard segment.endElapsed >= range.lowerBound,
              segment.startElapsed <= range.upperBound else { return [] }
        var start = segment.startIndex
        var end = segment.endIndex
        if segment.startElapsed < range.lowerBound {
            start = max(start, session.track.index(atElapsed: range.lowerBound) ?? start)
        }
        if segment.endElapsed > range.upperBound {
            end = min(end, session.track.index(atElapsed: range.upperBound) ?? end)
        }
        guard end > start, end < session.track.count else { return [] }
        return session.track.points[start...end].map(\.clCoordinate)
    }

    private func coordinates(for segment: StateSegment) -> [CLLocationCoordinate2D] {
        guard segment.startIndex >= 0, segment.endIndex < session.track.count else { return [] }
        // Clip the segment the scrubber is inside, so the drawn track ends
        // exactly at the playhead rather than jumping a whole segment ahead.
        var start = segment.startIndex
        var end = segment.endIndex
        if let partialUpTo, segment.endElapsed > partialUpTo {
            end = min(end, session.track.index(atElapsed: partialUpTo) ?? segment.startIndex)
        }
        // Clip to the trim at both ends, per sample rather than per segment.
        // Filtering whole segments by overlap is not enough: a short session is
        // one long segment, so it overlaps any selection and gets drawn in full,
        // and the part being cut looks identical to the part being kept.
        if let trimRange, !trimIsRemoval {
            if segment.startElapsed < trimRange.lowerBound {
                start = max(start, session.track.index(atElapsed: trimRange.lowerBound) ?? start)
            }
            if segment.endElapsed > trimRange.upperBound {
                end = min(end, session.track.index(atElapsed: trimRange.upperBound) ?? end)
            }
        }
        guard end > start else { return [] }
        return session.track.points[start...end].map(\.clCoordinate)
    }

    // MARK: - Styling

    /// Colour carries speed; weight and opacity carry state.
    ///
    /// Keeping those on separate visual channels is what lets a rider read both
    /// at once. Encoding state as another hue would collide with the speed ramp
    /// and make neither legible.
    private func style(for segment: StateSegment) -> AnyShapeStyle {
        switch segment.state {
        case .foiling:
            return AnyShapeStyle(speedColour(segment.averageSpeed))
        case .riding:
            return AnyShapeStyle(speedColour(segment.averageSpeed).opacity(0.75))
        case .slow:
            // Grey vanishes against imagery, so the muted states lift to white
            // on a dark base map.
            return AnyShapeStyle(style.isDark
                ? Color.white.opacity(0.6)
                : Color.gray.opacity(0.55))
        case .stopped:
            return AnyShapeStyle(style.isDark
                ? Color.white.opacity(0.4)
                : Color.gray.opacity(0.35))
        case .fall:
            return AnyShapeStyle(Color.red.opacity(0.65))
        }
    }

    private func lineWidth(for segment: StateSegment) -> Double {
        switch segment.state {
        case .foiling: 5
        case .riding: 3.5
        case .slow: 2
        case .stopped: 1.5
        case .fall: 3
        }
    }

    /// Speed ramp, scaled to this session rather than to an absolute range.
    ///
    /// An absolute scale would render a light-wind session entirely blue and a
    /// windy one entirely red, which tells you nothing about either. Scaling to
    /// the session's own spread means the ramp always separates that session's
    /// fast runs from its slow ones.
    private func speedColour(_ speed: Double) -> Color {
        let top = max(summary.maxSpeed, 1)
        let bottom = top * 0.35
        let t = max(0, min(1, (speed - bottom) / max(0.1, top - bottom)))
        return Color(
            hue: 0.58 - 0.58 * t,   // blue → green → yellow → red
            saturation: 0.85,
            brightness: 0.95
        )
    }

    // MARK: - Camera

    private func frameSelection() {
        let points: [CLLocationCoordinate2D]
        if let selectedRun, let run = summary.runs.first(where: { $0.index == selectedRun }) {
            points = session.track.points[run.startIndex...run.endIndex].map(\.clCoordinate)
        } else {
            points = session.track.points.map(\.clCoordinate)
        }
        guard let region = MKCoordinateRegion(fitting: points) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(region)
        }
    }
}

// MARK: - Markers

struct FallMarker: View {
    let fall: Fall

    var body: some View {
        ZStack {
            Circle()
                .fill(.red)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 14, height: 14)
        }
        // A low-confidence detection is drawn faintly rather than asserted.
        .opacity(0.5 + 0.5 * fall.confidence)
    }
}

struct ManeuverMarker: View {
    let maneuver: Maneuver

    var body: some View {
        Circle()
            .fill(maneuver.isDry ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .opacity(0.4 + 0.6 * maneuver.confidence)
    }
}

// MARK: - Bridges

extension Geo.Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension TrackPoint {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MKCoordinateRegion {
    /// A region containing every coordinate, with a little breathing room.
    init?(fitting coordinates: [CLLocationCoordinate2D], padding: Double = 1.35) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = Swift.min(minLat, c.latitude); maxLat = Swift.max(maxLat, c.latitude)
            minLon = Swift.min(minLon, c.longitude); maxLon = Swift.max(maxLon, c.longitude)
        }
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                // A floor stops a single-point or very short track zooming to
                // street level, where it is just a dot.
                latitudeDelta: Swift.max((maxLat - minLat) * padding, 0.002),
                longitudeDelta: Swift.max((maxLon - minLon) * padding, 0.002)
            )
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Map style

/// Which base map to draw under the track.
///
/// Satellite matters more here than in most apps: on open water the standard
/// map is a featureless blue field with nothing to orient by, while imagery
/// shows the shoreline, sandbars and channels that explain why a session went
/// the way it did.
enum MapStyleOption: String, CaseIterable, Identifiable, Sendable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Map"
        case .hybrid: "Hybrid"
        case .imagery: "Satellite"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: "map"
        case .hybrid: "globe.americas"
        case .imagery: "globe.americas.fill"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .imagery: .imagery(elevation: .flat)
        }
    }

    /// Whether the base map is dark, so overlays can pick a readable contrast.
    var isDark: Bool { self != .standard }
}

/// Cycles the base map, styled to sit over either a light or dark one.
struct MapStyleButton: View {
    @Binding var selection: MapStyleOption

    var body: some View {
        Menu {
            Picker("Map style", selection: $selection) {
                ForEach(MapStyleOption.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                }
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.subheadline)
                .padding(9)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Map style")
    }
}

/// The speed colour ramp, explained.
///
/// The track is coloured by speed and nothing on screen said so. A legend is
/// the difference between a pretty gradient and a readable one — and because
/// the ramp is scaled to each session rather than to an absolute range, the
/// end labels carry the actual numbers.
struct SpeedLegend: View {
    let maxSpeed: Double
    let units: UnitPreferences
    var onDark: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.speed(maxSpeed * 0.35, unit: units.speed, decimals: 0, includeSymbol: false))
            LinearGradient(
                colors: (0...8).map { i in
                    Color(hue: 0.58 - 0.58 * (Double(i) / 8), saturation: 0.85, brightness: 0.95)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 64, height: 6)
            .clipShape(Capsule())
            Text(Format.speed(maxSpeed, unit: units.speed, decimals: 0))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(onDark ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}


/// One end of a trim selection, on the map.
struct TrimMarker: View {

    let isStart: Bool
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.orange : Color.yellow)
                .frame(width: isActive ? 30 : 22, height: isActive ? 30 : 22)
                .overlay {
                    Circle().stroke(.white, lineWidth: 2.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)

            Image(systemName: isStart ? "chevron.right" : "chevron.left")
                .font(.system(size: isActive ? 14 : 11, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
        }
        // The end being dragged grows, so the eye can find it without hunting
        // through the other forty passes crossing the same water.
        .animation(.snappy(duration: 0.15), value: isActive)
        .accessibilityLabel(isStart ? "Trim start" : "Trim end")
    }
}
