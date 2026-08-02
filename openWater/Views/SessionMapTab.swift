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
    var onTrim: (SessionTrim, Bool) -> Void = { _, _ in }

    @Environment(AppSettings.self) private var settings

    /// The ramp the track is drawn with, so the legend cannot claim a
    /// different range from the colours beside it.
    private var speedScale: SpeedScale {
        SpeedScale(
            speeds: session.track.speed,
            movingAbove: session.sport.thresholds.movingSpeed
        )
    }

    @State private var elapsed: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var foilFilter: TrackMapView.FoilFilter = .everything
    @State private var minimumSpeed: Double = 0
    @State private var showFalls = true
    @State private var showManeuvers = false

    @State private var isTrimming = false
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0
    @State private var trimEdge: TrackMapView.TrimEdge?
    @State private var trimMode: TrimMode = .trim

    /// Derived once per session rather than per frame. See `makeChartSamples`
    /// and `TrimPreview.Index`.
    @State private var chartSamples: [(elapsed: TimeInterval, speed: Double)] = []
    @State private var previewIndex: TrimPreview.Index?

    enum TrimMode: String, CaseIterable, Identifiable {
        case trim = "Trim"
        case removeSegment = "Remove Segment"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .trim:
                "Keeps what is between the handles."
            case .removeSegment:
                "Cuts the middle out; the ends are joined."
            }
        }
    }

    /// Reveal the track only as far as the playhead.
    ///
    /// Off by default: the first thing a rider wants is the whole session. It
    /// is the single most useful switch on the screen once they start scrubbing,
    /// though, because a partial track is the only way to tell which of forty
    /// overlapping passes came first.
    @AppStorage("mapPartialTrack") private var showPartialTrack = false

    private var duration: TimeInterval { max(1, session.track.duration) }

    /// How much recording is waiting behind the trim, named in the menu so the
    /// rider can see there is something to get back without tapping to find out.
    private var restoreTitle: String {
        guard let first = session.rawPoints.first?.timestamp,
              let last = session.rawPoints.last?.timestamp else {
            return "Restore full recording"
        }
        let cut = last.timeIntervalSince(first) - session.track.duration
        guard cut > 1 else { return "Restore full recording" }
        return "Restore full recording (+\(Format.duration(cut)))"
    }

    /// Index of the sample under the playhead.
    private var index: Int {
        session.track.index(atElapsed: elapsed) ?? 0
    }

    var body: some View {
        // A split rather than the panel floating over the map on a safe-area
        // inset: nested insets fought with the tab bar's and the transport row
        // ended up underneath it.
        VStack(spacing: 0) {
            // The trim panel is tall enough to swallow the screen, and the map
            // is the thing being edited — it keeps a third of the height and
            // the panel scrolls inside what is left.
            map
            panel
        }
        // The trim bar's start handle lives in the edge-swipe zone, so reaching
        // for it popped the session instead of grabbing the handle.
        .interactivePopGesture(enabled: !isTrimming)
        // Everything derived from the track that does not change while it is
        // being edited, built once when the session appears rather than on
        // every frame of a drag.
        .task(id: session.id) {
            let track = session.track
            let derived = await Task.detached(priority: .userInitiated) {
                (samples: Self.makeChartSamples(track), index: TrimPreview.Index(track: track))
            }.value
            guard !Task.isCancelled else { return }
            chartSamples = derived.samples
            previewIndex = derived.index
        }
    }

    // MARK: - Map

    private var map: some View {
        TrackMapView(
            session: session,
            summary: summary,
            selectedRun: selectedRun,
            // Not while trimming. `trimRange` below already marks the
            // selection, and passing it as a highlight as well made the map's
            // cached base layer depend on a value that changes sixty times a
            // second — which rebuilt the whole track on every frame of a drag.
            highlight: nil,
            showFalls: showFalls,
            showManeuvers: showManeuvers,
            minimumSpeed: minimumSpeed,
            foilFilter: foilFilter,
            partialUpTo: showPartialTrack ? elapsed : nil,
            playhead: isScrubbing || elapsed > 0 ? elapsed : nil,
            trimRange: isTrimming ? trimStart...max(trimStart + 1, trimEnd) : nil,
            activeTrimEdge: trimEdge,
            trimIsRemoval: trimMode == .removeSegment,
            style: settings.mapStyle,
            units: settings.units
        )
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottomLeading) {
            SpeedLegend(
                scale: speedScale,
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
                MapChromeButton(action: onFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full screen map")

                // Out of the overflow menu and onto the map. Choosing the base
                // layer is the most-used thing here and the only one with a
                // running cost — satellite tiles are a download every time the
                // map moves — so it should not take two taps and a read.
                MapStyleButton(selection: Bindable(settings).mapStyle)

                mapOptions
            }
        }
        .padding(10)
        .mapChrome(onDark: settings.mapStyle.isDark)
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
                Button(restoreTitle, systemImage: "arrow.uturn.backward") {
                    onTrim(.none, false)
                }
            }

            Divider()

            Toggle("Show partial track", systemImage: "timeline.selection", isOn: $showPartialTrack)
            Toggle("Show falls", systemImage: "figure.fall", isOn: $showFalls)
            Toggle("Show turns", systemImage: "arrow.triangle.turn.up.right.diamond", isOn: $showManeuvers)

            Divider()

            Menu("Minimum speed") {
                Button("Off") { minimumSpeed = 0 }
                ForEach([5.0, 7.5, 10.0, 12.5], id: \.self) { speed in
                    Button(Format.speed(speed, unit: settings.units.speed, decimals: 0)) {
                        minimumSpeed = speed
                    }
                }
            }
        } label: {
            MapChromeButton { Image(systemName: "ellipsis") }
        }
        .accessibilityLabel("Map options")
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 10) {
            // The sport, the scissors and the play button all step aside while
            // trimming: the navigation bar already names the session and the
            // mode picker names what is being done to it, so the row is pure
            // decoration exactly when the map needs the height most.
            if !isTrimming {
                HStack {
                Text(session.sport.displayName)
                    .font(.title3.weight(.bold))
                Spacer()
                if session.trim.isTrimmed {
                    Label("Trimmed", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Trim session")

                Button(action: onReplay) {
                    Image(systemName: "play.fill")
                        .font(.subheadline)
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Replay session")
                }
            }

            if isTrimming {
                trimHeader
                TrimTimeline(
                    samples: chartSamples,
                    duration: duration,
                    start: $trimStart,
                    end: $trimEnd,
                    active: $trimEdge,
                    invertSelection: trimMode == .removeSegment
                )
                .frame(height: 62)
                HStack(spacing: 14) {
                    endpointStepper("Start", value: $trimStart,
                                    limit: 0...max(0, trimEnd - 10))
                    endpointStepper("End", value: $trimEnd,
                                    limit: min(duration, trimStart + 10)...duration)
                }
                trimStats
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
    ///
    /// Cached rather than computed in `body`: it never changes for a given
    /// session, and it was being rebuilt on every frame of a trim drag along
    /// with everything else the timeline touches.
    static func makeChartSamples(_ track: Track) -> [(elapsed: TimeInterval, speed: Double)] {
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

    /// Switching mode reseeds: a trim's ends and a cut's middle are not the
    /// same selection, and carrying one over produces a nonsense default —
    /// "remove the whole session" being the obvious one.
    func reseed(for mode: TrimMode) {
        switch mode {
        case .trim:
            trimStart = 0
            trimEnd = duration
        case .removeSegment:
            trimStart = duration * 0.4
            trimEnd = duration * 0.6
        }
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
        VStack(spacing: 6) {
            Picker("Mode", selection: $trimMode) {
                ForEach(TrimMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .onChange(of: trimMode) { _, mode in
                withAnimation(.snappy) { reseed(for: mode) }
            }

            Text(trimMode.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One end, with the nudge buttons. Dragging is for finding the moment;
    /// these are for landing on it — a second either way is not something a
    /// thumb can do on a bar this wide.
    func endpointStepper(
        _ title: String,
        value: Binding<TimeInterval>,
        limit: ClosedRange<TimeInterval>
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    nudge(value, by: -1, within: limit)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 28)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityLabel("\(title) back one second")

                Text(Format.duration(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 52)

                Button {
                    nudge(value, by: 1, within: limit)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 30, height: 28)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityLabel("\(title) forward one second")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func nudge(
        _ value: Binding<TimeInterval>,
        by seconds: TimeInterval,
        within limit: ClosedRange<TimeInterval>
    ) {
        guard limit.lowerBound <= limit.upperBound else { return }
        value.wrappedValue = min(max(limit.lowerBound, value.wrappedValue + seconds), limit.upperBound)
    }

    /// What the session would look like if this were saved.
    ///
    /// Computed straight off the track's own prefix arrays rather than by
    /// rebuilding and re-analysing — that happens once, on Save. A rider
    /// dragging a handle needs the number to follow their thumb, and
    /// re-running the whole analysis at sixty frames a second to tell them so
    /// would make the control unusable.
    var trimStats: some View {
        let preview = TrimPreview(
            track: session.track,
            index: previewIndex,
            range: trimStart...max(trimStart + 1, trimEnd),
            isRemoval: trimMode == .removeSegment
        )
        return HStack(alignment: .top, spacing: 0) {
            statColumn("Distance", Format.distance(preview.distance, unit: settings.units.distance))
            statColumn("Avg Speed", Format.speed(preview.averageSpeed, unit: settings.units.speed, decimals: 1))
            statColumn("Max Speed", Format.speed(preview.maxSpeed, unit: settings.units.speed, decimals: 1))
        }
        .padding(.vertical, 2)
    }

    private func statColumn(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    var trimControls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) { isTrimming = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")

            Button {
                apply(asNewActivity: true)
            } label: {
                Text("Save as New")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(!isSelectionUsable)

            Button {
                apply(asNewActivity: false)
            } label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isSelectionUsable)
        }
    }

    /// A selection has to leave something behind, and be worth doing.
    private var isSelectionUsable: Bool {
        let span = trimEnd - trimStart
        guard span >= 10 else { return false }
        return trimMode == .trim ? true : span < duration - 10
    }

    private func apply(asNewActivity: Bool) {
        let trim = trimMode == .trim
            ? selectedTrim
            : session.trim.removing(start: trimStart, end: trimEnd)
        onTrim(trim, asNewActivity)
        withAnimation(.snappy) { isTrimming = false }
    }
}

/// What a selection would leave behind, read off the track's prefix arrays.
///
/// Not a re-analysis. The real numbers come from rebuilding the track on Save;
/// these are the same three figures computed directly, so they can follow a
/// dragging thumb without running the whole engine sixty times a second. They
/// agree with the saved result to within the sample either side of a boundary.
struct TrimPreview {

    /// Precomputed once per session so a range maximum is not a full scan.
    ///
    /// Distance and time are already prefix sums on the track — subtracting two
    /// entries is free. The maximum was not, and it was the one figure being
    /// recomputed over ten thousand samples on every frame of a drag. A block
    /// maximum turns that into a walk of `n / blockSize` blocks plus at most two
    /// partial blocks: exact, and about two hundred times less work.
    struct Index: Equatable {
        static let blockSize = 64
        let blockMax: [Double]

        init(track: Track) {
            var maxima: [Double] = []
            maxima.reserveCapacity(track.count / Self.blockSize + 1)
            var i = 0
            while i < track.count {
                let end = min(i + Self.blockSize, track.count)
                maxima.append(track.speed[i..<end].max() ?? 0)
                i = end
            }
            blockMax = maxima
        }

        func maximum(in range: ClosedRange<Int>, speeds: [Double]) -> Double {
            let size = Self.blockSize
            let firstWhole = (range.lowerBound + size - 1) / size
            let lastWhole = (range.upperBound + 1) / size - 1

            guard firstWhole <= lastWhole else {
                // Inside a single block, or spanning a boundary with no whole
                // block between: just look at the samples.
                return speeds[range.lowerBound...range.upperBound].max() ?? 0
            }

            var peak = 0.0
            let headEnd = firstWhole * size - 1
            if headEnd >= range.lowerBound {
                peak = max(peak, speeds[range.lowerBound...headEnd].max() ?? 0)
            }
            for block in firstWhole...lastWhole where block < blockMax.count {
                peak = max(peak, blockMax[block])
            }
            let tailStart = (lastWhole + 1) * size
            if tailStart <= range.upperBound {
                peak = max(peak, speeds[tailStart...range.upperBound].max() ?? 0)
            }
            return peak
        }
    }

    let distance: Double
    let averageSpeed: Double
    let maxSpeed: Double

    init(track: Track, index: Index?, range: ClosedRange<TimeInterval>, isRemoval: Bool) {
        guard track.count > 1,
              let lower = track.index(atElapsed: range.lowerBound),
              let upper = track.index(atElapsed: range.upperBound),
              upper > lower else {
            distance = 0; averageSpeed = 0; maxSpeed = 0
            return
        }

        let kept: [ClosedRange<Int>] = isRemoval
            // Everything but the selection: the two ends that get joined.
            ? [0...lower, upper...(track.count - 1)].filter { $0.lowerBound < $0.upperBound }
            : [lower...upper]

        var metres = 0.0
        var seconds = 0.0
        var peak = 0.0
        for piece in kept {
            metres += track.cumulativeDistance[piece.upperBound] - track.cumulativeDistance[piece.lowerBound]
            seconds += track.elapsed[piece.upperBound] - track.elapsed[piece.lowerBound]
            peak = max(peak, index?.maximum(in: piece, speeds: track.speed)
                            ?? track.speed[piece.lowerBound...piece.upperBound].max() ?? 0)
        }

        distance = metres
        averageSpeed = seconds > 0 ? metres / seconds : 0
        maxSpeed = peak
    }
}

/// QuickTime's trim bar, drawn in one coordinate space.
///
/// The speed profile is painted here rather than borrowed from the chart, and
/// that is the point. Laying the handles over a Swift Charts view meant asking
/// it where its plot area was and trusting the answer through every layout
/// pass — and when the answer was wrong by a margin, a handle would sit off the
/// side of the screen or an end would appear to jump. One `GeometryReader`,
/// one width, one mapping from seconds to points, used by the drawing and the
/// gesture alike: there is nothing left to disagree.
struct TrimTimeline: View {

    let samples: [(elapsed: TimeInterval, speed: Double)]
    let duration: TimeInterval

    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    /// Which end the finger is on, published so the map can mark it.
    @Binding var active: TrackMapView.TrimEdge?

    /// In remove-segment mode the selection is what goes, so the shading flips:
    /// the middle is dimmed and the ends stay bright.
    var invertSelection: Bool = false

    /// Handles are 16 points wide; anything narrower is hard to catch with a
    /// thumb, and the two of them must never cross.
    private let handleWidth: CGFloat = 16
    private let minimumSpan: TimeInterval = 10

    /// Where the finger went down, and where the two ends were at that moment.
    ///
    /// A gesture keeps one `startLocation` for its whole life, so a change in it
    /// means a new gesture — which is how the grabbed end is re-decided even
    /// when the previous drag never delivered its `onEnded`. Comparing against
    /// the positions captured *then* rather than the live ones also stops the
    /// choice flipping under the finger as the selection moves.
    @State private var gestureOrigin: CGFloat = .nan
    @State private var grabbedStartX: CGFloat = 0
    @State private var grabbedEndX: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let startX = x(for: start, in: width)
            let endX = x(for: end, in: width)

            ZStack(alignment: .topLeading) {
                sparkline(size: geometry.size)

                if invertSelection {
                    Rectangle()
                        .fill(.red.opacity(0.30))
                        .frame(width: max(0, endX - startX))
                        .offset(x: startX)
                } else {
                    Rectangle()
                        .fill(.black.opacity(0.35))
                        .frame(width: max(0, startX))
                    Rectangle()
                        .fill(.black.opacity(0.35))
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)
                }

                RoundedRectangle(cornerRadius: 6)
                    .stroke(invertSelection ? Color.red : Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, endX - startX), height: height)
                    .offset(x: startX)

                handle(isStart: true, isActive: active == .start)
                    .frame(height: height)
                    .offset(x: startX)
                handle(isStart: false, isActive: active == .end)
                    .frame(height: height)
                    .offset(x: max(0, endX - handleWidth))
            }
            .frame(width: width, height: height)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // A drag that is mostly vertical belongs to the panel
                        // scrolling past, not to a handle. Without this the bar
                        // claims every touch that lands on it and the panel
                        // cannot be scrolled at all.
                        guard active != nil
                                || abs(value.translation.width) > abs(value.translation.height)
                        else { return }
                        if active == nil || value.startLocation.x != gestureOrigin {
                            gestureOrigin = value.startLocation.x
                            grabbedStartX = startX
                            grabbedEndX = endX
                            let x = value.startLocation.x
                            active = abs(x - grabbedStartX) <= abs(x - grabbedEndX) ? .start : .end
                        }
                        let time = TimeInterval(value.location.x / max(width, 1)) * duration
                        switch active {
                        case .start:
                            // `end - minimumSpan` goes negative on a session
                            // shorter than the minimum span, and `min` then
                            // drags the start below zero — which formats as
                            // "--:--" and makes every downstream number
                            // nonsense. Clamp the ceiling, not just the floor.
                            start = min(max(0, time), max(0, end - minimumSpan))
                        case .end:
                            end = max(min(duration, time), min(duration, start + minimumSpan))
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in
                        active = nil
                        gestureOrigin = .nan
                    }
            )
        }
    }

    /// Seconds to points, clamped so a handle can never be drawn off the bar.
    private func x(for time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard duration > 0, width > 0 else { return 0 }
        let fraction = min(max(0, time / duration), 1)
        return CGFloat(fraction) * width
    }

    /// The speed profile, filled. Not a chart — just the shape, so the rider can
    /// see which part of the session they are keeping.
    private func sparkline(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            guard samples.count > 1, duration > 0 else { return }
            let peak = max(samples.map(\.speed).max() ?? 1, 0.1)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: canvasSize.height))
            for sample in samples {
                let px = CGFloat(min(max(0, sample.elapsed / duration), 1)) * canvasSize.width
                let py = canvasSize.height * (1 - CGFloat(sample.speed / peak) * 0.92)
                path.addLine(to: CGPoint(x: px, y: py))
            }
            path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
            path.closeSubpath()

            context.fill(path, with: .color(.accentColor.opacity(0.25)))
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
    }

    private func handle(isStart: Bool, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isActive ? Color.orange : (invertSelection ? Color.red : Color.yellow))
            .frame(width: handleWidth)
            .overlay {
                Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
    }
}
