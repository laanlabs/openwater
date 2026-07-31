import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// Full-screen track with replay.
///
/// A static heatmap tells you *where* you were fast. Replaying the session tells
/// you *what happened* — which run the fast one was, how the gybe before it went,
/// where you dropped off the foil. On a track with forty overlapping passes that
/// is the difference between a pretty picture and something you can learn from,
/// because the playhead disambiguates what the geometry cannot.
///
/// The replay is time-based rather than sample-based: the playhead moves through
/// elapsed seconds and everything is interpolated, so a 1 Hz track scrubs
/// smoothly and the speed on screen matches the speed at that instant rather
/// than at the nearest fix.
struct SessionPlaybackView: View {

    let session: Session
    let summary: SessionSummary

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var speedMultiplier: Double = 30
    @State private var camera: MapCameraPosition = .automatic
    @State private var followsPlayhead = true
    @State private var showChrome = true
    @State private var trailOnly = false

    /// 20 Hz gives a playhead that moves smoothly without waking the CPU more
    /// than the display needs.
    private let tick: TimeInterval = 1.0 / 20.0

    private var duration: TimeInterval { max(1, session.track.duration) }

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showChrome { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if showChrome { transport.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .onTapGesture { withAnimation(.snappy) { showChrome.toggle() } }
        .statusBarHidden(!showChrome)
        .task(id: isPlaying) { await runPlayback() }
        .onAppear { frameWholeTrack() }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            // The full track, always visible as context. In trail mode it drops
            // to a ghost so the played portion stands out.
            ForEach(summary.segments) { segment in
                MapPolyline(coordinates: coordinates(for: segment))
                    .stroke(
                        trailColour(for: segment),
                        style: StrokeStyle(
                            lineWidth: trailOnly ? 2 : lineWidth(for: segment),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            // The portion played so far, drawn over the top in full colour.
            if trailOnly {
                ForEach(playedSegments) { segment in
                    MapPolyline(coordinates: coordinates(for: segment))
                        .stroke(
                            speedColour(segment.averageSpeed),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }
            }

            ForEach(summary.fallSummary.falls.filter { $0.elapsed <= elapsed }) { fall in
                Annotation("", coordinate: fall.coordinate.clCoordinate, anchor: .center) {
                    FallMarker(fall: fall)
                }
                .annotationTitles(.hidden)
            }

            if let position = session.track.coordinate(atElapsed: elapsed) {
                Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                    Playhead(speed: currentSpeed, maxSpeed: summary.maxSpeed)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// Segments entirely before the playhead, for the trail.
    private var playedSegments: [StateSegment] {
        summary.segments.filter { $0.startElapsed <= elapsed }
    }

    private func coordinates(for segment: StateSegment) -> [CLLocationCoordinate2D] {
        guard segment.startIndex >= 0, segment.endIndex < session.track.count else { return [] }
        // Clip the segment the playhead is inside, so the trail ends exactly at
        // the playhead rather than snapping forward a whole segment.
        let end = trailOnly && segment.endElapsed > elapsed
            ? (session.track.index(atElapsed: elapsed) ?? segment.startIndex)
            : segment.endIndex
        guard end > segment.startIndex else { return [] }
        return session.track.points[segment.startIndex...end].map(\.clCoordinate)
    }

    private func trailColour(for segment: StateSegment) -> Color {
        guard trailOnly else {
            switch segment.state {
            case .foiling: return speedColour(segment.averageSpeed)
            case .riding: return speedColour(segment.averageSpeed).opacity(0.7)
            case .slow: return .gray.opacity(0.5)
            case .stopped: return .gray.opacity(0.3)
            case .fall: return .red.opacity(0.6)
            }
        }
        return .gray.opacity(0.25)
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

    /// Scaled to this session's own spread, so a light-wind day is not rendered
    /// entirely blue and a windy one entirely red.
    private func speedColour(_ speed: Double) -> Color {
        let top = max(summary.maxSpeed, 1)
        let bottom = top * 0.35
        let t = max(0, min(1, (speed - bottom) / max(0.1, top - bottom)))
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.85, brightness: 0.95)
    }

    private var currentSpeed: Double {
        session.track.speed(atElapsed: elapsed)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }

            Spacer()

            readout

            Spacer()

            Menu {
                Toggle("Trail only", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $trailOnly)
                Toggle("Follow playhead", systemImage: "location.viewfinder", isOn: $followsPlayhead)
                Divider()
                Button("Fit whole track", systemImage: "arrow.up.left.and.arrow.down.right") {
                    followsPlayhead = false
                    frameWholeTrack()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.headline)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Live values at the playhead — the point of scrubbing is to see what was
    /// happening at a moment, not just where it was.
    private var readout: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(Format.speed(currentSpeed, unit: settings.units.speed,
                                  decimals: 1, includeSymbol: false))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(settings.units.speed.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                Text(Format.duration(elapsed))
                    .font(.system(size: 15, design: .rounded))
                    .monospacedDigit()
                Text("of \(Format.duration(duration))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let state = stateAtPlayhead {
                VStack(spacing: 0) {
                    Image(systemName: state == .foiling ? "airplane" : "water.waves")
                        .font(.system(size: 13))
                        .foregroundStyle(state == .foiling ? .green : .secondary)
                    Text(state.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    private var stateAtPlayhead: RideState? {
        guard let index = session.track.index(atElapsed: elapsed),
              summary.states.indices.contains(index) else { return nil }
        return summary.states[index]
    }

    private var transport: some View {
        VStack(spacing: 8) {
            // A speed strip under the scrubber, so you can see where the fast
            // bits are and jump straight to them instead of hunting.
            speedStrip
                .frame(height: 26)
                .padding(.horizontal)

            Slider(
                value: Binding(
                    get: { elapsed },
                    set: { elapsed = $0; if followsPlayhead { centreOnPlayhead() } }
                ),
                in: 0...duration
            )
            .padding(.horizontal)

            HStack(spacing: 18) {
                Button { seek(by: -30) } label: {
                    Image(systemName: "gobackward.30")
                        .font(.title3)
                }

                Button {
                    if elapsed >= duration - 0.05 { elapsed = 0 }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }

                Button { seek(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                }

                Menu {
                    ForEach([1.0, 5, 10, 30, 60, 120], id: \.self) { rate in
                        Button("\(Int(rate))×") { speedMultiplier = rate }
                    }
                } label: {
                    Text("\(Int(speedMultiplier))×")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .frame(minWidth: 42)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.bottom, 10)
        }
        .background(.thinMaterial)
    }

    /// The whole session's speed as a horizontal strip, aligned to the scrubber.
    private var speedStrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let buckets = max(1, Int(width / 2))
            HStack(spacing: 0) {
                ForEach(0..<buckets, id: \.self) { i in
                    let t = duration * Double(i) / Double(buckets)
                    Rectangle()
                        .fill(speedColour(session.track.speed(atElapsed: t)))
                        .frame(width: width / Double(buckets))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                // Playhead marker on the strip.
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: width * (elapsed / duration))
            }
        }
    }

    // MARK: - Playback

    private func runPlayback() async {
        guard isPlaying else { return }
        while isPlaying, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(tick))
            guard isPlaying else { return }

            elapsed = min(duration, elapsed + tick * speedMultiplier)
            if followsPlayhead { centreOnPlayhead() }

            if elapsed >= duration {
                isPlaying = false
                return
            }
        }
    }

    private func seek(by delta: TimeInterval) {
        elapsed = min(duration, max(0, elapsed + delta))
        if followsPlayhead { centreOnPlayhead() }
    }

    private func centreOnPlayhead() {
        guard let position = session.track.coordinate(atElapsed: elapsed) else { return }
        // No animation: at 60× the camera would spend its whole time easing
        // toward a point the playhead has already left, and the map would lag
        // visibly behind the marker.
        camera = .region(MKCoordinateRegion(
            center: position.clCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        ))
    }

    private func frameWholeTrack() {
        guard let region = MKCoordinateRegion(
            fitting: session.track.points.map(\.clCoordinate)
        ) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { camera = .region(region) }
    }
}

/// The moving marker. Sized and coloured by speed so the replay reads at a
/// glance even when the map is zoomed out.
struct Playhead: View {
    let speed: Double
    let maxSpeed: Double

    private var colour: Color {
        let top = max(maxSpeed, 1)
        let t = max(0, min(1, (speed - top * 0.35) / max(0.1, top * 0.65)))
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.9, brightness: 0.95)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(colour.opacity(0.3))
                .frame(width: 30, height: 30)
            Circle()
                .fill(colour)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(.white, lineWidth: 2.5)
                .frame(width: 14, height: 14)
        }
        .shadow(radius: 2)
    }
}
