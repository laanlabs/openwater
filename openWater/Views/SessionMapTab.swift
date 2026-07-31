import Charts
import OpenWaterCore
import SwiftUI

/// The session as a map you can scrub through.
///
/// This is the screen a rider opens a session to look at, so it is the one the
/// detail view lands on. The map takes the room, and the panel underneath
/// answers the question a static heatmap cannot: *what was happening at that
/// moment?* Drag the chart or step the clock and the speed, the distance
/// covered and the heart rate all follow the playhead, which is marked on the
/// track.
///
/// The filters matter as much as the scrubber. A foil session's track is two
/// different activities drawn on top of each other — flying, and everything
/// else — and being able to look at one without the other is the difference
/// between a picture and something you can read.
struct SessionMapTab: View {

    let session: Session
    let summary: SessionSummary

    @Binding var selectedRun: Int?

    var onFullScreen: () -> Void = {}
    var onReplay: () -> Void = {}

    @Environment(AppSettings.self) private var settings

    @State private var elapsed: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var foilFilter: TrackMapView.FoilFilter = .everything
    @State private var minimumSpeed: Double = 0
    @State private var showFalls = true
    @State private var showManeuvers = false

    /// Reveal the track only as far as the playhead.
    ///
    /// Off by default: the first thing a rider wants is the whole session. It
    /// is the single most useful switch on the screen once they start scrubbing,
    /// though, because a partial track is the only way to tell which of forty
    /// overlapping passes came first.
    @AppStorage("mapPartialTrack") private var showPartialTrack = false

    private var duration: TimeInterval { max(1, session.track.duration) }

    /// Index of the sample under the playhead.
    private var index: Int {
        session.track.index(atElapsed: elapsed) ?? 0
    }

    var body: some View {
        // A split rather than the panel floating over the map on a safe-area
        // inset: nested insets fought with the tab bar's and the transport row
        // ended up underneath it.
        VStack(spacing: 0) {
            map
            panel
        }
    }

    // MARK: - Map

    private var map: some View {
        TrackMapView(
            session: session,
            summary: summary,
            selectedRun: selectedRun,
            showFalls: showFalls,
            showManeuvers: showManeuvers,
            minimumSpeed: minimumSpeed,
            foilFilter: foilFilter,
            partialUpTo: showPartialTrack ? elapsed : nil,
            playhead: isScrubbing || elapsed > 0 ? elapsed : nil,
            style: settings.mapStyle
        )
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottomLeading) {
            SpeedLegend(
                maxSpeed: summary.maxSpeed,
                units: settings.units,
                onDark: settings.mapStyle.isDark
            )
            .padding(.leading, 12)
            .padding(.bottom, 8)
        }
    }

    private var topChrome: some View {
        HStack(alignment: .top) {
            if let wind = session.effectiveWind {
                WindDial(wind: wind, units: settings.units)
            }

            Spacer()

            VStack(spacing: 8) {
                Button(action: onFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Full screen map")

                mapOptions
            }
        }
        .padding(10)
    }

    /// Everything that changes what the map is showing, in one menu.
    private var mapOptions: some View {
        Menu {
            Picker("Show", selection: $foilFilter) {
                ForEach(TrackMapView.FoilFilter.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol).tag(option)
                }
            }

            Divider()

            Toggle("Show partial track", systemImage: "timeline.selection", isOn: $showPartialTrack)
            Toggle("Show falls", systemImage: "figure.fall", isOn: $showFalls)
            Toggle("Show turns", systemImage: "arrow.triangle.turn.up.right.diamond", isOn: $showManeuvers)

            Divider()

            Picker("Map style", selection: Bindable(settings).mapStyle) {
                ForEach(MapStyleOption.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                }
            }

            Menu("Minimum speed") {
                Button("Off") { minimumSpeed = 0 }
                ForEach([5.0, 7.5, 10.0, 12.5], id: \.self) { speed in
                    Button(Format.speed(speed, unit: settings.units.speed, decimals: 0)) {
                        minimumSpeed = speed
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .padding(9)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Map options")
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.sport.displayName)
                    .font(.title3.weight(.bold))
                Spacer()
                if foilFilter != .everything || minimumSpeed > 0 || showPartialTrack {
                    Button {
                        withAnimation(.snappy) {
                            foilFilter = .everything
                            minimumSpeed = 0
                            showPartialTrack = false
                        }
                    } label: {
                        Label("Filtered", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption)
                    }
                }
                Button(action: onReplay) {
                    Image(systemName: "play.fill")
                        .font(.subheadline)
                        .padding(9)
                        .background(.quaternary, in: Circle())
                }
                .accessibilityLabel("Replay session")
            }

            liveNumbers
            speedChart
            transport
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                .fill(.background)
                .shadow(color: .black.opacity(0.10), radius: 8, y: -2)
        }
    }

    /// The three figures at the playhead. At zero they read as the session's
    /// starting state rather than its totals, which is the honest thing for a
    /// scrubber sitting at the beginning.
    private var liveNumbers: some View {
        HStack(alignment: .top, spacing: 0) {
            CardStat(
                group: "Speed",
                groupColour: .orange,
                label: settings.units.speed.symbol,
                value: Format.speed(session.track.speed[safe: index] ?? 0,
                                    unit: settings.units.speed, decimals: 1, includeSymbol: false)
            )
            CardStat(
                group: "Distance",
                groupColour: .blue,
                label: settings.units.distance.symbol,
                value: Format.distance(session.track.cumulativeDistance[safe: index] ?? 0,
                                       unit: settings.units.distance, includeSymbol: false)
            )
            CardStat(
                group: "Heart Rate",
                groupColour: .pink,
                label: "BPM",
                value: session.track.points[safe: index]?.heartRate
                    .map { String(Int($0.rounded())) } ?? "—"
            )
        }
    }

    /// Speed over the session, with the playhead on it.
    ///
    /// Draggable, because a slider under a chart is a second control for the
    /// same thing — the chart *is* the timeline, and the fast bits are visible
    /// on it, which is where a rider actually wants to jump to.
    private var speedChart: some View {
        Chart {
            ForEach(chartSamples, id: \.elapsed) { sample in
                AreaMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("Speed", settings.units.speed.convert(fromMetresPerSecond: sample.speed))
                )
                .foregroundStyle(.tint.opacity(0.25))
                .interpolationMethod(.monotone)
            }
            ForEach(chartSamples, id: \.elapsed) { sample in
                LineMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("Speed", settings.units.speed.convert(fromMetresPerSecond: sample.speed))
                )
                .foregroundStyle(.tint)
                .interpolationMethod(.monotone)
            }
            RuleMark(x: .value("Playhead", elapsed))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text("\(Int(speed))").font(.caption2)
                    }
                }
            }
        }
        .frame(height: 82)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isScrubbing = true
                                guard let plot = proxy.plotFrame else { return }
                                let x = value.location.x - geometry[plot].origin.x
                                if let time: TimeInterval = proxy.value(atX: x) {
                                    elapsed = min(max(0, time), duration)
                                }
                            }
                            .onEnded { _ in isScrubbing = false }
                    )
            }
        }
    }

    /// One point per pixel or so. A three-hour track is ten thousand samples and
    /// Swift Charts will happily try to draw all of them, on a chart ninety-six
    /// points tall.
    private var chartSamples: [(elapsed: TimeInterval, speed: Double)] {
        let track = session.track
        guard track.count > 1 else { return [] }
        let step = max(1, track.count / 400)
        return stride(from: 0, to: track.count, by: step).map {
            (track.elapsed[$0], track.speed[$0])
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                step(-10)
            } label: {
                Image(systemName: "minus")
                    .font(.headline)
                    .frame(width: 44, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
            .accessibilityLabel("Back ten seconds")

            VStack(spacing: 0) {
                Text(Format.duration(elapsed))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("of \(Format.duration(duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                step(10)
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 44, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
            .accessibilityLabel("Forward ten seconds")
        }
        .buttonStyle(.plain)
    }

    private func step(_ seconds: TimeInterval) {
        withAnimation(.snappy(duration: 0.15)) {
            elapsed = min(max(0, elapsed + seconds), duration)
        }
    }
}

// MARK: - Wind

/// Wind direction as a dial, the way it appears on the water.
struct WindDial: View {

    let wind: Wind
    let units: UnitPreferences

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 64, height: 64)

            // The arrow rides the rim rather than sitting in the middle, so it
            // does not collide with the numbers. It points the way the wind is
            // *going*, which is what a rider reads off a flag; the cardinal
            // underneath is the direction it comes from, which is what everyone
            // says out loud.
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .offset(y: -24)
                .rotationEffect(.degrees(wind.directionFrom))

            VStack(spacing: -1) {
                Text(speedText)
                    .font(.system(size: 13, weight: .semibold))
                Text(Format.cardinal(wind.directionFrom))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Wind \(Format.cardinal(wind.directionFrom))\(wind.speed == nil ? "" : ", \(speedText)")")
    }

    private var speedText: String {
        guard let speed = wind.speed else { return Format.bearing(wind.directionFrom, includeCardinal: false) }
        return Format.speed(speed, unit: units.speed, decimals: 0)
    }
}
