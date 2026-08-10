import MapKit
import OpenWaterCore
import SwiftUI

/// Where on the water the bumps were working.
///
/// Two things are drawn. The **glides** are the fine grain: each one a coloured
/// stretch of track, brighter the faster it was, so a rider can see the section
/// of coast that was giving. The **legs** are the coarse grain, and they only
/// appear on a shuttle day: `SessionShape` splits the session where the rider
/// was carried back to the top, so three runs down the same river read as three
/// runs rather than as one confusing tangle.
///
/// The thresholds sit at the bottom of this screen rather than in Settings,
/// because this is where a rider finds out they disagree with them. Every one
/// was arrived at by arguing with a real session, and none is a fact about the
/// world — a big board in small swell holds a glide at a speed a race foil
/// would call slogging.
struct DownwindDetailView: View {

    @State private var session: Session
    @State private var summary: SessionSummary

    var onSetWind: () -> Void = {}

    init(session: Session, summary: SessionSummary, onSetWind: @escaping () -> Void = {}) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        self.onSetWind = onSetWind
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// The run being singled out on the map, if any.
    @State private var selectedRun: Int?
    @State private var isMapFullScreen = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var isRecomputing = false

    private var glides: [Glide] { summary.downwind.glides }
    private var legs: [SessionLeg] { summary.shape.legs }

    /// Legs are worth drawing only when there is more than one — on an
    /// ordinary session the single leg is the whole track, and outlining it
    /// says nothing the track has not already said.
    private var showsLegs: Bool { legs.count > 1 }

    /// Was there a downwind run at all?
    ///
    /// This screen is about the run — where you went and how long you were up
    /// for. It used to be about glides, and was three rounds of feedback in
    /// being told so: "we don't want all this glide detail, it should be on
    /// the DW run, that's all."
    ///
    /// Glides are still detected, still archived, still adjustable from the
    /// thresholds below. They are simply not what a downwind rider opens this
    /// screen to read.
    private var hasRun: Bool { !downwindRuns.isEmpty }

    /// Every downwind run in the session.
    ///
    /// Grouped, not raw. The segmenter finds every weave across the bumps, and
    /// on a lapping day that was thirty-four "runs" for an afternoon a rider
    /// would describe as six. `GroupedRun` merges consecutive stretches on the
    /// same point of sail, and the Runs tab uses the same grouping so the two
    /// screens always agree.
    private var downwindRuns: [GroupedRun] {
        GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
            .filter { $0.kind == .downwind }
    }

    /// The track between a run's first and last stretch.
    private func coordinates(of run: GroupedRun) -> [CLLocationCoordinate2D] {
        let points = session.track.points
        let inside = points.indices.filter {
            session.track.elapsed[$0] >= run.startElapsed
                && session.track.elapsed[$0] <= run.endElapsed
        }
        return inside.map { points[$0].clCoordinate }
    }

    private func midpoint(of run: GroupedRun) -> CLLocationCoordinate2D? {
        let line = coordinates(of: run)
        guard !line.isEmpty else { return nil }
        return line[line.count / 2]
    }

    private func maxSpeed(from start: Int, to end: Int) -> Double {
        guard start <= end, end < session.track.count else { return 0 }
        return (start...end).reduce(0.0) { max($0, session.track.speed[$1]) }
    }

    private func runIndex(of lane: SessionRibbon.Lane) -> (lower: Int, upper: Int) {
        guard let run = summary.runs[safe: lane.runIndex] else { return (0, 0) }
        return (run.startIndex, run.endIndex)
    }

    private var units: UnitPreferences { settings.units }

    /// What this session was actually analysed with, the rider's changes
    /// included.
    private var thresholds: SportThresholds {
        settings.thresholds(for: session.sport)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if hasRun {
                    runsCard
                    mapCard
                } else {
                    nothingFound
                }

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Downwind")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · Downwind")
        .overlay {
            if isRecomputing {
                ProgressView("Re-reading the session…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .fullScreenCover(isPresented: $isMapFullScreen) {
            NavigationStack {
                map
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Glides")
                    .navigationBarTitleDisplayMode(.inline)
                    .feedbackButton("Session · Glides")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isMapFullScreen = false }
                        }
                    }
            }
        }
    }

    // MARK: - Map

    /// Every downwind run, one row each.
    ///
    /// The same shape as a Runs tab row on purpose — a rider moving between
    /// the two screens should not have to re-learn how to read a line.
    private var runsCard: some View {
        let runs = downwindRuns
        let totalDistance = runs.reduce(0) { $0 + $1.distance }
        let totalTime = runs.reduce(0) { $0 + $1.duration }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(runs.count == 1 ? "1 downwind run" : "\(runs.count) downwind runs")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 8)
                if runs.count > 1 {
                    Text("\(Format.distance(totalDistance, unit: units.distance)) · \(Format.shortDuration(totalTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 10)

            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 { Divider().padding(.vertical, 2) }
                Button {
                    select(selectedRun == run.id ? nil : run.id)
                } label: {
                HStack(spacing: 10) {
                    if runs.count > 1 {
                        Text("\(run.number)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(selectedRun == nil || selectedRun == run.id
                                        ? GroupedRun.Kind.downwind.colour
                                        : Color.secondary.opacity(0.4),
                                        in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(Format.distance(run.distance, unit: units.distance)) · \(Format.shortDuration(run.duration))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if run.isLinked { LinkedChip() }
                        }
                        Text("\(Format.speed(run.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(run.maxSpeed, unit: units.speed, decimals: 1)) max")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 8)

                    if let alignment = run.alignment {
                        Text("\(Int(alignment.rounded()))° off")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(alignment <= 20 ? .green : .secondary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(selectedRun == run.id
                            ? AnyShapeStyle(GroupedRun.Kind.downwind.colour.opacity(0.12))
                            : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .cardChrome()
    }

    private var mapCard: some View {
        map
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    isMapFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Expand map")
            }
            .overlay(alignment: .bottomLeading) {
                if selectedRun != nil {
                    Button("Show all") { select(nil) }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
    }

    private var map: some View {
        Map(position: $camera) {
            // The whole session, faded, as context — same as Upwind so the two
            // screens read as the same kind of picture.
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Each downwind run drawn whole and numbered, the way the upwind
            // screen draws its beats.
            ForEach(downwindRuns) { run in
                let chosen = selectedRun == nil || selectedRun == run.id
                // The kind's own colour, shared with the Runs tab's map so a
                // downwind run is the same orange on both. `.accentColor` was
                // used here and resolves unreliably inside a MapPolyline —
                // the same line drew orange unselected and system blue
                // selected — which is the sibling of the `.tint` problem.
                MapPolyline(coordinates: coordinates(of: run))
                    .stroke(chosen ? GroupedRun.Kind.downwind.colour
                            : Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: selectedRun == run.id ? 7 : 5,
                                               lineCap: .round, lineJoin: .round))
            }

            ForEach(downwindRuns) { run in
                if let start = midpoint(of: run) {
                    let chosen = selectedRun == nil || selectedRun == run.id
                    Annotation("", coordinate: start, anchor: .center) {
                        Button { select(selectedRun == run.id ? nil : run.id) } label: {
                            Text("\(run.number)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: selectedRun == run.id ? 24 : 18,
                                       height: selectedRun == run.id ? 24 : 18)
                                .background(chosen ? GroupedRun.Kind.downwind.colour
                                            : Color.secondary.opacity(0.35),
                                            in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
    }

    private func coordinates(of glide: Glide) -> [CLLocationCoordinate2D] {
        session.track.points[glide.startIndex...glide.endIndex].map(\.clCoordinate)
    }

    private func midpoint(of glide: Glide) -> CLLocationCoordinate2D {
        session.track.points[(glide.startIndex + glide.endIndex) / 2].clCoordinate
    }

    private var sortedGlides: [Glide] {
        glides.sorted { $0.duration > $1.duration }
    }

    /// Where this glide sits in the list below, which is sorted longest-first,
    /// so the number on the map is the number on the row.
    private func position(of glide: Glide) -> Int {
        (sortedGlides.firstIndex { $0.id == glide.id } ?? 0) + 1
    }

    /// Choose a glide and frame it, or clear the choice and show the session.
    ///
    /// Framing is the point. A four-kilometre glide inside an hour of laps is a
    /// thin thread on a map scaled to the whole session, and picking it out by
    /// eye is exactly the work this screen exists to save.
    private func select(_ id: Int?) {
        withAnimation(.snappy) {
            selectedRun = id
            guard let id, let run = downwindRuns.first(where: { $0.id == id }) else {
                camera = .automatic
                return
            }
            camera = .region(region(covering: coordinates(of: run)))
        }
    }

    private func region(covering coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max()
        else { return MKCoordinateRegion() }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                // A floor on the span, or a short glide fills the screen at a
                // zoom where nothing around it is recognisable.
                latitudeDelta: max(0.004, (maxLat - minLat) * 1.4),
                longitudeDelta: max(0.004, (maxLon - minLon) * 1.4)
            )
        )
    }

    /// The same ramp the ribbon and the track use, so a fast glide here is the
    /// same colour as a fast run there.
    private func speedColour(_ speed: Double) -> Color {
        let top = max(summary.maxSpeed, 1)
        let bottom = top * 0.35
        let t = max(0, min(1, (speed - bottom) / max(0.1, top - bottom)))
        return Color(hue: 0.58 - 0.58 * t, saturation: 0.85, brightness: 0.95)
    }

    // MARK: - Legs

    private var legsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Runs") {
                Text("split where you were driven back")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Text("\(leg.id + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.tint, in: Circle())

                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.distance(leg.distance, unit: units.distance))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("\(Format.shortDuration(leg.duration)) · \(Format.speed(leg.averageSpeed, unit: units.speed, decimals: 1)) avg")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        // Only a leg that actually ran somewhere gets a
                        // direction. Over a zigzag the bearing describes the
                        // drift, and "1° off dead downwind" on an hour of laps
                        // that happened to creep downwind is a sentence about
                        // nothing.
                        if leg.isRun, let alignment = leg.alignment {
                            Text("\(Int(alignment.rounded()))° off")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(alignment <= 20 ? .green : .secondary)
                        } else if leg.isRun {
                            Text(Format.cardinal(leg.bearing))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("laps")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            if legs.contains(where: { $0.isRun && $0.alignment != nil }) {
                Text("\"Off\" is how far the run's line sat from dead downwind.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardChrome()
    }

    // MARK: - Glide list

    // MARK: - Prose

    /// Why there is nothing here.
    ///
    /// An empty screen would leave a rider guessing whether the app looks for
    /// glides at all. It does, and these are the four things it wants — said
    /// plainly, with their current values, so a session that found none is
    /// legible as a flat day rather than as a broken feature.
    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No downwind run in this session", systemImage: "water.waves")
                .font(.subheadline.weight(.medium))

            Text("This session ends about where it started, so there is no run to describe — a downwinder goes somewhere. If it was one and this is wrong, the wind direction is the usual reason; the glides that make up a run have to be all four of these:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                criterion("At least \(Int(thresholds.glideMinimumDuration)) seconds")
                criterion("Sailed more than \(Int(thresholds.glideDownwindAngle))° off the wind — a bump can only push you the way it is going")
                criterion("At least \(Int(thresholds.glideSpeedFraction * 100))% of your typical downwind speed")
                criterion("Speed rising \(Int(thresholds.glideMinimumGain * 100))% out of the lull before it")
            }

            Text("All four are adjustable at the bottom of this screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !summary.downwind.usedMotionData {
                Text("This session has no motion data either, which is what tells working from gliding most clearly. A watch or phone recording gives a better answer than an imported file.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardChrome()
    }

    private func criterion(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Thresholds

    private var footer: some View {
        AnalysisFooter(
            session: session,
            summary: summary,
            // Glides are direction-tested, so without wind every stretch of
            // fast riding qualifies whichever way it was pointing.
            needs: [.windDirection, .motionData],
            isBusy: isRecomputing,
            onSetWind: onSetWind,
            onReanalyse: recompute
        ) {
            ThresholdSlider(
                title: "Off the wind",
                value: settings.thresholdBinding(for: session.sport, \.glideDownwindAngle,
                                                 default: defaults.glideDownwindAngle),
                range: 90...150, step: 5,
                format: { "\(Int($0))°" },
                note: "How far off the wind you have to be pointing. A bump can only push you the way it is going, so riding across the swell does not count.",
                onCommit: recompute
            )
            ThresholdSlider(
                title: "At least this long",
                value: settings.thresholdBinding(for: session.sport, \.glideMinimumDuration,
                                                 default: defaults.glideMinimumDuration),
                range: 2...20, step: 1,
                format: { "\(Int($0)) s" },
                note: "Below this it is a nudge off a bit of chop rather than a glide.",
                onCommit: recompute
            )
            ThresholdSlider(
                title: "Share of your downwind pace",
                value: settings.thresholdBinding(for: session.sport, \.glideSpeedFraction,
                                                 default: defaults.glideSpeedFraction),
                range: 0.5...1.0, step: 0.05,
                format: { "\(Int($0 * 100))%" },
                note: "Measured against your median speed going downwind, so a current that slows every downwind leg does not raise the bar. Near 100% splits your riding in half, since half of it is below its own median by definition.",
                onCommit: recompute
            )
            ThresholdSlider(
                title: "Speed rise out of the lull",
                value: settings.thresholdBinding(for: session.sport, \.glideMinimumGain,
                                                 default: defaults.glideMinimumGain),
                range: 0...0.3, step: 0.01,
                format: { "\(Int($0 * 100))%" },
                note: "The bump gives you speed. Without a rise there is nothing to separate gliding from riding along at one speed.",
                onCommit: recompute
            )
        }
    }

    private var defaults: SportThresholds { session.sport.thresholds }

    /// Re-run the analysis with the rider's thresholds and keep the result.
    ///
    /// Saved to the library rather than held here, so the rest of the app
    /// agrees with what this screen shows — the same discipline the Upwind
    /// screen follows when the wind is changed.
    private func recompute() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary {
                session = edited
                summary = newSummary
                select(nil)
            }
            isRecomputing = false
        }
    }
}
