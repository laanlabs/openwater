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
    @State private var selectedLeg: Int?
    @State private var samples: [(elapsed: TimeInterval, vmg: Double)] = []
    @State private var isSettingWind = false
    @State private var isRecomputing = false
    @State private var isMapFullScreen = false

    init(session: Session, summary: SessionSummary, polar: PolarAnalysis) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        _polar = State(initialValue: polar)
    }

    private var wind: Wind { polar.wind }

    private func colour(_ tack: Tack) -> Color {
        tack == .port ? .red : .green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The headline first, then the working. This card used to sit
                // on Summary with this screen behind it; now that Analysis
                // lists topics rather than stacking cards, the answer and the
                // evidence belong together on one screen.
                UpwindCard(polar: polar, runs: summary.runs, units: settings.units)
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

                Text("A leg is continuous sailing on one tack above a beam reach. VMG is measured as ground actually made toward the wind over the leg's time — wandering costs it, so these are honest numbers, not speed × cos(angle).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Upwind")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard legs.isEmpty else { return }
            legs = upwindLegs(track: session.track, wind: wind)
            samples = computeVMGSamples()
        }
        .sheet(isPresented: $isSettingWind) {
            WindSetterView(session: session) { direction, speed, swell in
                applyWind(direction: direction, speed: speed, swell: swell)
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
        }
    }

    /// Every number on this screen is measured from one direction, so
    /// changing it re-runs the whole chain: analysis, polar, legs, samples —
    /// and the library keeps the saved result so the rest of the app agrees.
    private func applyWind(direction: Double, speed: Double?, swell: Double?) {
        isRecomputing = true
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let current = session
        Task {
            let edited = await Task.detached {
                var edits = Session.Edits(session: current)
                edits.windDirection = direction
                edits.windSpeed = speed
                edits.swellHeight = swell
                return current.applying(edits, categories: categories, overrides: overrides)
            }.value
            library.save(edited)
            if let newSummary = edited.summary, let newPolar = newSummary.polar {
                session = edited
                summary = newSummary
                polar = newPolar
                legs = upwindLegs(track: edited.track, wind: newPolar.wind)
                samples = computeVMGSamples()
                selectedLeg = nil
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
                selectedLeg = nil
            }
            isRecomputing = false
        }
    }

    /// The rider's own idea of what an upwind leg is.
    private func upwindLegs(track: Track, wind: Wind) -> [UpwindLeg] {
        let t = settings.thresholds(for: session.sport)
        return UpwindLegFinder.legs(
            track: track,
            wind: wind,
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
            MapPolyline(coordinates: windAxis)
                .stroke(.indigo.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))

            ForEach(legs) { leg in
                MapPolyline(coordinates: session.track.points[leg.startIndex...leg.endIndex].map(\.clCoordinate))
                    .stroke(
                        colour(leg.tack).opacity(selectedLeg == nil || selectedLeg == leg.id ? 0.9 : 0.25),
                        style: StrokeStyle(lineWidth: selectedLeg == leg.id ? 6 : 4, lineCap: .round)
                    )

                // Number-only dots: eleven full "n · 54°" capsules stacked on
                // the same stretch of river buried each other, and the angles
                // looked missing when they were merely covered. The angle
                // appears when a leg is chosen, and always lives in the list.
                Annotation("", coordinate: session.track.points[leg.midIndex].clCoordinate, anchor: .center) {
                    Button {
                        withAnimation(.snappy) {
                            selectedLeg = selectedLeg == leg.id ? nil : leg.id
                        }
                    } label: {
                        if selectedLeg == leg.id {
                            Text("\(leg.index + 1) · \(Int(leg.meanAngle.rounded()))° · \(Format.speed(leg.vmg, unit: settings.units.speed, decimals: 1)) VMG")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(colour(leg.tack), in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        } else {
                            Text("\(leg.index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(colour(leg.tack).opacity(0.9), in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .overlay(alignment: .topTrailing) { windBadge }
        .overlay(alignment: .bottomLeading) {
            // The counterpart of choosing a leg: everything else dims when one
            // is selected, so putting it back cannot depend on the rider
            // re-finding an 18-point dot they may have tapped by accident.
            if selectedLeg != nil {
                Button {
                    withAnimation(.snappy) { selectedLeg = nil }
                } label: {
                    Label("Show all legs", systemImage: "xmark.circle.fill")
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
                    .rotationEffect(.degrees(wind.directionFrom))
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
        .padding(10)
    }

    /// A line through the middle of the track along the wind's axis, long
    /// enough to cross the whole session.
    private var windAxis: [CLLocationCoordinate2D] {
        let points = session.track.points
        guard !points.isEmpty else { return [] }
        let midLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let midLon = points.map(\.longitude).reduce(0, +) / Double(points.count)
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let span = max((lats.max()! - lats.min()!), (lons.max()! - lons.min()!) * cos(midLat * .pi / 180)) * 0.75
        let radians = wind.directionFrom * .pi / 180
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
                if let beat = polar.beat {
                    RectangleMark(
                        xStart: .value("From", beat.startElapsed / 60),
                        xEnd: .value("To", beat.endElapsed / 60),
                        yStart: .value("Bottom", chartFloor),
                        yEnd: .value("Top", chartCeiling)
                    )
                    .foregroundStyle(.tint.opacity(0.12))
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
                    .foregroundStyle(colour(leg.tack).opacity(0.7))
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
                if polar.beat != nil {
                    LegKey(colour: Color.accentColor.opacity(0.25), label: "Best beat")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var units: SpeedUnit { settings.units.speed }

    /// Signed VMG per sample, downsampled by bucket mean — peaks matter less
    /// here than the shape of working versus running. Computed once on appear:
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
                sum += wind.vmg(speed: track.speed[k], heading: track.course[k])
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
            Text("LEGS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(legs) { leg in
                    Button {
                        selectedLeg = selectedLeg == leg.id ? nil : leg.id
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
                        .background(selectedLeg == leg.id ? colour(leg.tack).opacity(0.1) : .clear)
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
