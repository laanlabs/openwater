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

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            // Ghost layer first, so the highlighted content draws over it.
            if selectedRun != nil || highlight != nil || foilingOnly || minimumSpeed > 0 {
                MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                    .stroke(.gray.opacity(0.22), lineWidth: 2)
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

            if let start = session.track.points.first?.clCoordinate {
                Marker("Start", systemImage: "flag", coordinate: start)
                    .tint(.green)
            }
            if let end = session.track.points.last?.clCoordinate {
                Marker("End", systemImage: "flag.checkered", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: selectedRun) { _, _ in frameSelection() }
        .onAppear { frameSelection() }
    }

    // MARK: - Filtering

    private var visibleSegments: [StateSegment] {
        summary.segments.filter { segment in
            if let selectedRun, segment.runIndex != selectedRun { return false }
            if foilingOnly, segment.state != .foiling { return false }
            if minimumSpeed > 0, segment.maxSpeed < minimumSpeed { return false }
            if let highlight {
                let overlaps = segment.startElapsed <= highlight.upperBound
                    && segment.endElapsed >= highlight.lowerBound
                if !overlaps { return false }
            }
            return true
        }
    }

    private func coordinates(for segment: StateSegment) -> [CLLocationCoordinate2D] {
        guard segment.startIndex >= 0, segment.endIndex < session.track.count else { return [] }
        return session.track.points[segment.startIndex...segment.endIndex].map(\.clCoordinate)
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
            return AnyShapeStyle(Color.gray.opacity(0.55))
        case .stopped:
            return AnyShapeStyle(Color.gray.opacity(0.35))
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
