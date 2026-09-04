import Charts
import MapKit
import OpenWaterCore
import SwiftUI

/// The upwind story in full: every leg on the map with its working angle, the
/// VMG over time, and the numbers per leg.
///
/// The summary card says what the beat was worth; this screen says *where* —
/// which tack carried it, which leg was the good one, and what angle each was
/// actually sailed at. Port legs are red and starboard legs green, because
/// those are the colours the sport already painted on every bow.
///
/// Two things here are the rider's to change. **Which stretch** — the best
/// beat is the finder's pick, but tapping one leg and then another measures
/// the legs between them the same honest way, for the rider who wants the
/// twelve legs up the river and not the finder's best kilometre. And **which
/// way** — made-good is measured straight into the wind unless a course is
/// set, and on a river the wind's bearing is a bank. See `CourseSetterView`.
struct UpwindDetailView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// Local copies, because the wind is editable *here*: a new direction
    /// re-runs the analysis, the library gets the saved result, and this
    /// screen re-derives everything it shows without asking the parent.
    @State private var session: Session
    @State private var summary: SessionSummary
    @State private var polar: PolarAnalysis

    @State private var legs: [UpwindLeg] = []
    /// The legs the rider has chosen, by index, always contiguous: a beat is
    /// a stretch of time, and a stretch skips nothing. One tap picks a leg;
    /// a tap on another leg stretches the choice to include it.
    @State private var selection: ClosedRange<Int>?
    /// The chosen stretch, measured. Kept as state rather than derived so the
    /// prefix sums are built once per choice, not once per layout pass.
    @State private var chosen: PolarAnalysis.BothTacksVMG?
    /// What the chosen stretch contains besides the chosen legs, when that
    /// is worth saying — see `measureSelection`.
    @State private var chosenNote: String?
    @State private var samples: [(elapsed: TimeInterval, vmg: Double)] = []
    @State private var isSettingWind = false
    @State private var isSettingCourse = false
    @State private var isRecomputing = false
    @State private var isMapFullScreen = false
    /// Which way the map is turned, so the badge arrows can turn the other
    /// way and keep pointing at the world rather than at the screen.
    @State private var mapHeading: Double = 0

    /// The parent's copy and its revision — see `SessionDetailView.revision`.
    /// Local state above lets this screen re-analyse in place; a new revision
    /// means the parent re-read the session, and the local copy yields to it.
    private let incoming: (session: Session, summary: SessionSummary, polar: PolarAnalysis)
    var revision: Int = 0

    init(session: Session, summary: SessionSummary, polar: PolarAnalysis, revision: Int = 0) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        _polar = State(initialValue: polar)
        incoming = (session, summary, polar)
        self.revision = revision
    }

    private var wind: Wind { polar.wind }

    /// The bearing made-good is measured toward, when it is not the wind's.
    private var course: Double? { polar.courseDirection }

    private func colour(_ tack: Tack) -> Color {
        tack == .port ? .red : .green
    }

    private func isSelected(_ leg: UpwindLeg) -> Bool {
        selection?.contains(leg.id) ?? false
    }

    /// The selection rule, in one place so the map and the list agree.
    ///
    /// Nothing chosen: this leg. This leg alone: nothing. A leg inside a
    /// wider choice: narrow to it — the rider is starting over from here.
    /// A leg outside: widen to reach it. So "legs 10 to 21" is two taps, and
    /// every state is one tap from the one the rider meant.
    private func toggle(_ leg: UpwindLeg) {
        withAnimation(.snappy) {
            guard let current = selection else {
                selection = leg.id...leg.id
                return
            }
            if current == leg.id...leg.id {
                selection = nil
            } else if current.contains(leg.id) {
                selection = leg.id...leg.id
            } else {
                selection = min(current.lowerBound, leg.id)...max(current.upperBound, leg.id)
            }
        }
    }

    private func clearSelection() {
        withAnimation(.snappy) { selection = nil }
    }

    /// Measure the chosen legs the way the best beat is measured — net
    /// displacement along the axis from the first leg's start to the last
    /// leg's end, over the time it took, tacks between them included.
    private func measureSelection() {
        guard let selection,
              let first = legs.first(where: { $0.id == selection.lowerBound }),
              let last = legs.first(where: { $0.id == selection.upperBound })
        else {
            chosen = nil
            chosenNote = nil
            return
        }
        var measure = PolarAnalysis.BothTacksVMG.measured(
            track: session.track, wind: wind, toward: course,
            from: first.startIndex, to: last.endIndex)
        // The finder counts legs as tack changes, which inside a beat is the
        // same thing. Inside a rider's choice it is not: legs 10 to 21 on a
        // river can hold a run back down between them, and every gybe on
        // the way counted as a "leg". The rider chose twelve; say twelve.
        measure?.legs = selection.count
        chosen = measure

        // And say what else is in there. A stretch is measured as time, so
        // a choice that straddles a run back down, or a rest on the beach,
        // pays for it in the number — which is right, and baffling unless
        // it is said. Only worth saying when it is a real share.
        let inLegs = legs.filter { selection.contains($0.id) }.reduce(0.0) { $0 + $1.duration }
        let span = last.endElapsed - first.startElapsed
        let between = span - inLegs
        if between > 60, between > span * 0.25 {
            chosenNote = "\(Format.shortDuration(between)) of this stretch was between those legs — a run back down, a rest — and the number pays for it. For a beat, choose legs sailed back to back."
        } else {
            chosenNote = nil
        }
    }

    /// "legs 10–21", or "leg 10".
    private var selectionLabel: String? {
        guard let selection else { return nil }
        if selection.count == 1 { return "leg \(selection.lowerBound + 1)" }
        return "legs \(selection.lowerBound + 1)–\(selection.upperBound + 1)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The headline first, then the working. This card used to sit
                // on Summary with this screen behind it; now that Analysis
                // lists topics rather than stacking cards, the answer and the
                // evidence belong together on one screen.
                UpwindCard(polar: polar, runs: summary.runs, units: settings.units,
                           chosen: chosen, chosenLabel: selectionLabel,
                           chosenNote: chosenNote, onClearChosen: clearSelection)
                    .cardChrome()

                if !polar.wind.hasSpeed {
                    NoWindSpeedCard(compact: true) { isSettingWind = true }
                }

                map
                    .frame(height: 320)
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
                    // Turning the phone opens the same map the button does.
                    .fullScreenInLandscape($isMapFullScreen)

                if legs.isEmpty {
                    ContentUnavailableView(
                        "No upwind legs",
                        systemImage: "arrow.up.forward",
                        description: Text("Nothing here was sailed above a beam reach for long enough to count as a leg.")
                    )
                } else {
                    vmgChart
                    legList
                }

                Text(course == nil
                     ? "A leg is continuous sailing on one tack above a beam reach. VMG is measured as ground actually made toward the wind over the leg's time — wandering costs it, so these are honest numbers, not speed × cos(angle). Tap a leg, then another, to measure the stretch between them. If the wind's bearing is not where you were going — up a river, say — set a course on the map and made-good is measured toward it instead."
                     : "A leg is continuous sailing on one tack above a beam reach. VMG here is ground actually made toward your course over the leg's time — wandering costs it, so these are honest numbers, not speed × cos(angle). Which legs count as upwind, and which tack, are still measured to the wind. Tap a leg, then another, to measure the stretch between them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .readableContentColumn()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Upwind")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · Upwind")
        .onAppear {
            guard legs.isEmpty else { return }
            legs = upwindLegs(track: session.track, wind: wind)
            samples = computeVMGSamples()
        }
        .onChange(of: revision) { _, _ in
            session = incoming.session
            summary = incoming.summary
            polar = incoming.polar
            legs = upwindLegs(track: session.track, wind: polar.wind)
            samples = computeVMGSamples()
            selection = nil
        }
        .onChange(of: selection) { _, _ in measureSelection() }
        .sheet(isPresented: $isSettingWind) {
            WindSetterView(session: session) { applied in
                apply { edits in
                    edits.windDirection = applied.windDirection
                    edits.windSpeed = applied.windSpeed
                    edits.windTimeline = applied.windTimeline
                    edits.swellHeight = applied.swellHeight
                    edits.swellDirection = applied.swellDirection
                    edits.currentSpeed = applied.currentSpeed
                    edits.currentDirectionToward = applied.currentDirectionToward
                }
            }
        }
        .sheet(isPresented: $isSettingCourse) {
            CourseSetterView(trackPoints: session.track.points, wind: wind,
                             initial: course) { direction in
                apply { edits in edits.courseDirection = direction }
            }
        }
        .fullScreenCover(isPresented: $isMapFullScreen) {
            // The same map, selection and all — a leg chosen in either place
            // is chosen in both.
            map
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    Button {
                        isMapFullScreen = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                    .padding(.top, 8)
                }
                .closesInPortrait()
        }
    }

    /// Every number on this screen is measured from one direction — two,
    /// with a course set — so changing either re-runs the whole chain:
    /// analysis, polar, legs, samples — and the library keeps the saved
    /// result so the rest of the app agrees.
    private func apply(_ change: @escaping @Sendable (inout Session.Edits) -> Void) {
        isRecomputing = true
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let current = session
        Task {
            let edited = await Task.detached {
                var edits = Session.Edits(session: current)
                change(&edits)
                return current.applying(edits, categories: categories, overrides: overrides)
            }.value
            library.save(edited)
            if let newSummary = edited.summary, let newPolar = newSummary.polar {
                session = edited
                summary = newSummary
                polar = newPolar
                legs = upwindLegs(track: edited.track, wind: newPolar.wind)
                samples = computeVMGSamples()
                selection = nil
            }
            isRecomputing = false
        }
    }

    // MARK: - Thresholds

    private var footer: some View {
        AnalysisFooter(
            session: session,
            summary: summary,
            // Every angle on this screen is measured from the direction; the
            // strength only adds context, but its absence is worth saying.
            needs: [.windDirection, .windSpeed],
            isBusy: isRecomputing,
            onSetWind: { isSettingWind = true },
            onReanalyse: reanalyse
        ) {
            ThresholdSlider(
                title: "Counts as upwind up to",
                value: settings.thresholdBinding(for: session.sport, \.upwindLegAngle,
                                                 default: session.sport.thresholds.upwindLegAngle),
                range: 50...100, step: 5,
                format: { "\(Int($0))° off the wind" },
                note: "Ninety is a beam reach — beyond it you are no longer climbing. Lower it if reaches are being counted as beats.",
                onCommit: reanalyse
            )
            ThresholdSlider(
                title: "Shortest leg by distance",
                value: settings.thresholdBinding(for: session.sport, \.upwindLegMinimumDistance,
                                                 default: session.sport.thresholds.upwindLegMinimumDistance),
                range: 20...400, step: 10,
                format: { "\(Int($0)) m" },
                note: "A real zig-zag is made of short tacks, so this sits low on purpose. Raise it if the list is full of scraps.",
                onCommit: reanalyse
            )
            ThresholdSlider(
                title: "Shortest leg by time",
                value: settings.thresholdBinding(for: session.sport, \.upwindLegMinimumDuration,
                                                 default: session.sport.thresholds.upwindLegMinimumDuration),
                range: 4...60, step: 2,
                format: { "\(Int($0)) s" },
                note: "Same idea in seconds — a fifteen-second tack is a real tack.",
                onCommit: reanalyse
            )
        }
    }

    /// Re-run everything from the track, then rebuild the legs and the chart.
    private func reanalyse() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary, let newPolar = newSummary.polar {
                session = edited
                summary = newSummary
                polar = newPolar
                legs = upwindLegs(track: edited.track, wind: newPolar.wind)
                samples = computeVMGSamples()
                selection = nil
            }
            isRecomputing = false
        }
    }

    /// The rider's own idea of what an upwind leg is, measured toward
    /// their course when they set one.
    private func upwindLegs(track: Track, wind: Wind) -> [UpwindLeg] {
        let t = settings.thresholds(for: session.sport)
        return UpwindLegFinder.legs(
            track: track,
            wind: wind,
            madeGoodToward: polar.courseDirection,
            upwindLimit: t.upwindLegAngle,
            minimumDistance: t.upwindLegMinimumDistance,
            minimumDuration: t.upwindLegMinimumDuration
        )
    }

    // MARK: - Map

    private var map: some View {
        Map {
            // The whole session as context, faded.
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // The wind axis, dashed across the water. This is what makes the
            // zig-zag legible as a *beat*: every leg reads against the line
            // it is trying to climb.
            MapPolyline(coordinates: axis(toward: wind.directionFrom))
                .stroke(.indigo.opacity(course == nil ? 0.55 : 0.3), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))

            // And the course, when there is one: the line the rider was
            // actually climbing, solid so it reads as the one that counts,
            // with the wind's axis left faint beside it for the comparison.
            if let course {
                MapPolyline(coordinates: axis(toward: course))
                    .stroke(.tint.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, dash: [14, 5]))
            }

            ForEach(legs) { leg in
                MapPolyline(coordinates: session.track.points[leg.startIndex...leg.endIndex].map(\.clCoordinate))
                    .stroke(
                        colour(leg.tack).opacity(selection == nil || isSelected(leg) ? 0.9 : 0.25),
                        style: StrokeStyle(lineWidth: isSelected(leg) ? 6 : 4, lineCap: .round)
                    )

                // Number-only dots: eleven full "n · 54°" capsules stacked on
                // the same stretch of river buried each other, and the angles
                // looked missing when they were merely covered. The angle
                // appears when a leg is chosen, and always lives in the list.
                Annotation("", coordinate: session.track.points[leg.midIndex].clCoordinate, anchor: .center) {
                    Button {
                        toggle(leg)
                    } label: {
                        if selection == leg.id...leg.id {
                            Text("\(leg.index + 1) · \(Int(leg.meanAngle.rounded()))° · \(Format.speed(leg.vmg, unit: settings.units.speed, decimals: 1)) VMG")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(colour(leg.tack), in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        } else {
                            // Inside a wider choice the dots stay dots — a
                            // dozen capsules would bury each other — but
                            // grow a little and keep their ring bold.
                            Text("\(leg.index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: isSelected(leg) ? 22 : 18, height: isSelected(leg) ? 22 : 18)
                                .background(colour(leg.tack).opacity(selection == nil || isSelected(leg) ? 0.9 : 0.5), in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: isSelected(leg) ? 2.5 : 1.5))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .onMapCameraChange(frequency: .continuous) { context in
            mapHeading = context.camera.heading
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                windBadge
                courseBadge
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            // The counterpart of choosing a leg: everything else dims when one
            // is selected, so putting it back cannot depend on the rider
            // re-finding an 18-point dot they may have tapped by accident.
            if let selectionLabel {
                Button {
                    clearSelection()
                } label: {
                    Label("Measuring \(selectionLabel) · clear", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .overlay {
            if isRecomputing {
                ZStack {
                    Color.black.opacity(0.2)
                    ProgressView()
                }
            }
        }
    }

    /// The wind, said plainly, and the way to change it. Every angle on this
    /// screen is measured from this one number — so it is shown large, with
    /// its provenance, and it is a button.
    private var windBadge: some View {
        Button {
            isSettingWind = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .rotationEffect(.degrees(wind.directionFrom - mapHeading))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Format.cardinal(wind.directionFrom)) \(Int(wind.directionFrom.rounded()))°"
                         + (wind.speed.map { " · \(Int(($0 * 1.94384).rounded())) kn" } ?? ""))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(wind.source.isEstimate ? "estimated · tap to set" : "tap to adjust")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// Where made-good is measured toward, and the way to change it. Under
    /// the wind badge because it answers the next question a rider asks
    /// after "is the wind right": "but I was not going that way".
    private var courseBadge: some View {
        Button {
            isSettingCourse = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 13, weight: .bold))
                    .rotationEffect(.degrees((course ?? wind.directionFrom) - mapHeading))
                    .foregroundStyle(course == nil ? .secondary : .primary)
                VStack(alignment: .leading, spacing: 0) {
                    if let course {
                        Text("toward \(Format.cardinal(course)) \(Int(course.rounded()))°")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("made good · \(Int(abs(Geo.angleDelta(from: wind.directionFrom, to: course)).rounded()))° off the wind")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("toward the wind")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("made good · tap to set a course")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: course == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(course.map { "Made good toward \(Int($0.rounded())) degrees, tap to adjust" }
                            ?? "Made good toward the wind, tap to set a course")
    }

    /// A line through the middle of the track along a bearing, long enough
    /// to cross the whole session.
    private func axis(toward bearing: Double) -> [CLLocationCoordinate2D] {
        let points = session.track.points
        guard !points.isEmpty else { return [] }
        let midLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let midLon = points.map(\.longitude).reduce(0, +) / Double(points.count)
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let span = max((lats.max()! - lats.min()!), (lons.max()! - lons.min()!) * cos(midLat * .pi / 180)) * 0.75
        let radians = bearing * .pi / 180
        let dLat = cos(radians) * span
        let dLon = sin(radians) * span / cos(midLat * .pi / 180)
        return [
            CLLocationCoordinate2D(latitude: midLat + dLat, longitude: midLon + dLon),
            CLLocationCoordinate2D(latitude: midLat - dLat, longitude: midLon - dLon),
        ]
    }

    // MARK: - Chart

    /// VMG through the session, with the legs painted underneath it.
    ///
    /// The line is the instantaneous component toward the wind — negative
    /// while running downwind, so the shape shows the whole rhythm of the
    /// session. The coloured lanes are the detected legs; the highlighted span
    /// is the best beat the summary card quotes.
    private var vmgChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VMG UPWIND")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                // The stretch the headline is about: the rider's choice when
                // they made one, otherwise the best beat.
                if let span = chosen ?? polar.beat {
                    RectangleMark(
                        xStart: .value("From", span.startElapsed / 60),
                        xEnd: .value("To", span.endElapsed / 60),
                        yStart: .value("Bottom", chartFloor),
                        yEnd: .value("Top", chartCeiling)
                    )
                    .foregroundStyle(.tint.opacity(chosen == nil ? 0.12 : 0.2))
                }

                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Minutes", sample.elapsed / 60),
                        y: .value("VMG", units.convert(fromMetresPerSecond: sample.vmg))
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }

                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))

                ForEach(legs) { leg in
                    RectangleMark(
                        xStart: .value("From", leg.startElapsed / 60),
                        xEnd: .value("To", leg.endElapsed / 60),
                        yStart: .value("Lane", chartFloor),
                        yEnd: .value("Lane", chartFloor + laneHeight)
                    )
                    .foregroundStyle(colour(leg.tack).opacity(selection == nil || isSelected(leg) ? 0.7 : 0.25))
                    .cornerRadius(1)
                }
            }
            .chartYScale(domain: chartFloor...chartCeiling)
            .chartXAxisLabel("minutes")
            .chartYAxisLabel(units.symbol)
            .frame(height: 170)

            HStack(spacing: 12) {
                LegKey(colour: .red, label: "Port legs")
                LegKey(colour: .green, label: "Starboard legs")
                if chosen != nil, let selectionLabel {
                    LegKey(colour: Color.accentColor.opacity(0.35), label: selectionLabel.capitalized)
                } else if polar.beat != nil {
                    LegKey(colour: Color.accentColor.opacity(0.25), label: "Best beat")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var units: SpeedUnit { settings.units.speed }

    /// Signed VMG per sample along the made-good axis, downsampled by bucket
    /// mean — peaks matter less here than the shape of working versus
    /// running. Computed once on appear:
    /// as a computed property it ran on every layout pass, and worse, the
    /// floor/lane/ceiling getters once referred to *each other* — laneHeight
    /// asked chartFloor which asked laneHeight, and the recursion took the app
    /// down the first time the chart drew.
    private func computeVMGSamples() -> [(elapsed: TimeInterval, vmg: Double)] {
        let track = session.track
        let target = 500
        let stride = max(1, track.count / target)
        var result: [(TimeInterval, Double)] = []
        var i = 0
        while i < track.count {
            let end = min(i + stride, track.count)
            var sum = 0.0
            for k in i..<end {
                sum += wind.vmg(speed: track.speed[k], heading: track.course[k], toward: course)
            }
            result.append((track.elapsed[(i + end - 1) / 2], sum / Double(end - i)))
            i = end
        }
        return result
    }

    /// The raw plot extremes, from the data alone — nothing below depends on
    /// anything that depends on this.
    private var extremes: (floor: Double, ceiling: Double) {
        let values = samples.map { units.convert(fromMetresPerSecond: $0.vmg) }
        let ceiling = max(1, (values.max() ?? 1) * 1.1)
        let floor = min(0, (values.min() ?? 0) * 1.1)
        return (floor, ceiling)
    }

    private var laneHeight: Double {
        let e = extremes
        return (e.ceiling - e.floor) * 0.06
    }

    private var chartCeiling: Double { extremes.ceiling }
    private var chartFloor: Double { extremes.floor - laneHeight }

    // MARK: - Legs

    private var legList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("LEGS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selection == nil
                     ? "tap one, then another, to measure a stretch"
                     : "tap a leg outside to widen · inside to start over")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            VStack(spacing: 0) {
                ForEach(legs) { leg in
                    Button {
                        toggle(leg)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(colour(leg.tack))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Leg \(leg.index + 1) · \(leg.tack == .port ? "Port" : "Starboard")")
                                    .font(.subheadline.weight(.medium))
                                Text("\(Format.distance(leg.distance, unit: settings.units.distance)) · \(Format.shortDuration(leg.duration)) · avg \(Format.speed(leg.averageSpeed, unit: units, decimals: 1))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Format.speed(leg.vmg, unit: units, decimals: 1)) VMG")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                Text("@ \(Int(leg.meanAngle.rounded()))°")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(isSelected(leg) ? colour(leg.tack).opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if leg.id != legs.last?.id {
                        Divider().padding(.leading, 32)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct LegKey: View {
    let colour: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colour)
                .frame(width: 14, height: 5)
            Text(label)
        }
    }
}
