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

    /// Apply a trim. The detail view owns saving it, because trimming re-runs
    /// the analysis and the whole screen has to pick up the new numbers.
    var onTrim: (SessionTrim) -> Void = { _ in }

    @Environment(AppSettings.self) private var settings

    @State private var elapsed: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var foilFilter: TrackMapView.FoilFilter = .everything
    @State private var minimumSpeed: Double = 0
    @State private var showFalls = true
    @State private var showManeuvers = false

    @State private var isTrimming = false
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0

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
            highlight: isTrimming ? trimStart...max(trimStart + 1, trimEnd) : nil,
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

            if session.trim.isTrimmed {
                Button("Restore full recording", systemImage: "arrow.uturn.backward") {
                    onTrim(.none)
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
                // Trimming lives next to the scrubber it operates on, not in a
                // menu: it is the thing a rider does to the timeline, and a
                // control that acts on what you are looking at should be where
                // you are looking.
                Button {
                    beginTrimming()
                } label: {
                    Image(systemName: "scissors")
                        .font(.subheadline)
                        .padding(9)
                        .background(.quaternary, in: Circle())
                }
                .accessibilityLabel("Trim session")

                Button(action: onReplay) {
                    Image(systemName: "play.fill")
                        .font(.subheadline)
                        .padding(9)
                        .background(.quaternary, in: Circle())
                }
                .accessibilityLabel("Replay session")
            }

            if isTrimming {
                trimHeader
                speedChart
                trimControls
            } else {
                liveNumbers
                speedChart
                transport
            }
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
            if !isTrimming {
                RuleMark(x: .value("Playhead", elapsed))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        // The axis is noise while trimming, and the yellow frame runs straight
        // through the labels.
        .chartYAxis(isTrimming ? .hidden : .automatic)
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
                if isTrimming {
                    TrimOverlay(
                        start: $trimStart,
                        end: $trimEnd,
                        duration: duration,
                        width: proxy.plotFrame.map { geometry[$0].width } ?? geometry.size.width
                    )
                    .offset(x: proxy.plotFrame.map { geometry[$0].origin.x } ?? 0)
                } else {
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

// MARK: - Trim

extension SessionMapTab {

    /// Open the trim, seeded with whatever is already set — or, on a session
    /// that has never been trimmed, with the app's suggestion. Riders record
    /// from the car park; offering the obvious cut beats making them find it.
    func beginTrimming() {
        // Seeded in the timeline that is on screen, never from the stored trim.
        //
        // `SessionTrim`'s offsets are measured from the start of the *recording*,
        // while the chart and this screen's clock are the *trimmed* track — so
        // feeding a stored trim straight back in put the end handle past the
        // right-hand edge of a chart it no longer belonged to. On an
        // already-trimmed session it read "from 21:08 to 45:12 of 30:01", with
        // one handle off the screen entirely.
        //
        // So a second trim narrows what is already kept, which is both
        // predictable and always visible. Widening is "Restore full recording"
        // and start again — offered in the map menu.
        if let suggested = session.suggestedTrim() {
            trimStart = min(max(0, suggested.startOffset), duration)
            trimEnd = min(suggested.endOffset ?? duration, duration)
        } else {
            trimStart = 0
            trimEnd = duration
        }
        if trimEnd - trimStart < 10 {
            trimStart = 0
            trimEnd = duration
        }
        withAnimation(.snappy) { isTrimming = true }
    }

    /// Convert the on-screen selection into offsets from the start of the
    /// recording, which is what a `SessionTrim` means.
    private var selectedTrim: SessionTrim {
        // Left at the far right? Then whatever the end already was stays.
        session.trim.narrowed(
            start: trimStart,
            end: trimEnd >= duration - 1 ? nil : trimEnd
        )
    }

    var trimHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keeping \(Format.duration(trimEnd - trimStart))")
                    .font(.headline)
                Text("from \(Format.duration(trimStart)) to \(Format.duration(trimEnd)) of \(Format.duration(duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var trimControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Cancel") {
                    withAnimation(.snappy) { isTrimming = false }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("Trim") {
                    onTrim(selectedTrim)
                    withAnimation(.snappy) { isTrimming = false }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(trimEnd - trimStart < 10)
            }
            .font(.headline)

            // Said out loud because it is the difference between a rider using
            // this and being frightened of it: the fixes are all still there.
            Text("Nothing is deleted. \"Restore full recording\" in the map menu puts every fix back, whenever you want it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// QuickTime's trim bar: a yellow frame over the timeline with a grab handle at
/// each end, everything outside it dimmed.
///
/// Copied deliberately. Trimming a recording by dragging its two ends is a
/// gesture people already have in their hands from every video app they have
/// ever used, and inventing a different one here would buy nothing.
struct TrimOverlay: View {

    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    let duration: TimeInterval
    let width: CGFloat

    /// Handles are 16 points wide; anything narrower is hard to catch with a
    /// thumb, and the two of them must never cross.
    private let handleWidth: CGFloat = 16
    private let minimumSpan: TimeInterval = 10

    /// Which end the current drag grabbed. Decided once, when the finger goes
    /// down, and held for the whole gesture — recomputing it per frame lets the
    /// selection flip ends underneath the finger as it crosses the midpoint.
    @State private var dragging: Edge?

    private enum Edge { case start, end }

    // Clamped on the way out as well as on the way in. A handle drawn from an
    // out-of-range value does not look wrong, it looks *absent* — it is simply
    // off the side of the chart, which is exactly how the last bug presented.
    private var startX: CGFloat {
        min(max(0, CGFloat(start / max(duration, 1)) * width), width - handleWidth)
    }
    private var endX: CGFloat {
        min(max(handleWidth, CGFloat(end / max(duration, 1)) * width), width)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim what is being cut.
            Rectangle()
                .fill(.black.opacity(0.35))
                .frame(width: max(0, startX))
            Rectangle()
                .fill(.black.opacity(0.35))
                .frame(width: max(0, width - endX))
                .offset(x: endX)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow, lineWidth: 3)
                .frame(width: max(handleWidth * 2, endX - startX))
                .offset(x: startX)

            handle(at: startX, isStart: true)
            handle(at: endX - handleWidth, isStart: false)
        }
        .frame(width: width)
        .contentShape(.rect)
        // One gesture over the whole bar rather than one per handle. A gesture
        // attached to a 16-point handle reports positions in *that* view's
        // coordinate space, so the arithmetic that turns a touch into a time
        // was working from a sixteen-point-wide world.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragging == nil {
                        let x = value.startLocation.x
                        dragging = abs(x - startX) <= abs(x - endX) ? .start : .end
                    }
                    let time = TimeInterval(value.location.x / max(width, 1)) * duration
                    switch dragging {
                    case .start:
                        start = min(max(0, time), end - minimumSpan)
                    case .end:
                        end = max(min(duration, time), start + minimumSpan)
                    case nil:
                        break
                    }
                }
                .onEnded { _ in dragging = nil }
        )
    }

    private func handle(at x: CGFloat, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.yellow)
            .frame(width: handleWidth)
            .overlay {
                Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }
}
