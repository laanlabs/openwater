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

    let session: Session
    let summary: SessionSummary
    let polar: PolarAnalysis

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var legs: [UpwindLeg] = []
    @State private var selectedLeg: Int?
    @State private var samples: [(elapsed: TimeInterval, vmg: Double)] = []

    private var wind: Wind { polar.wind }

    private func colour(_ tack: Tack) -> Color {
        tack == .port ? .red : .green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                map
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

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
            legs = UpwindLegFinder.legs(track: session.track, wind: wind)
            samples = computeVMGSamples()
        }
    }

    // MARK: - Map

    private var map: some View {
        Map {
            // The whole session as context, faded.
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            ForEach(legs) { leg in
                MapPolyline(coordinates: session.track.points[leg.startIndex...leg.endIndex].map(\.clCoordinate))
                    .stroke(
                        colour(leg.tack).opacity(selectedLeg == nil || selectedLeg == leg.id ? 0.9 : 0.25),
                        style: StrokeStyle(lineWidth: selectedLeg == leg.id ? 6 : 4, lineCap: .round)
                    )

                Annotation("", coordinate: session.track.points[leg.midIndex].clCoordinate, anchor: .center) {
                    Button {
                        selectedLeg = selectedLeg == leg.id ? nil : leg.id
                    } label: {
                        Text("\(leg.index + 1) · \(Int(leg.meanAngle.rounded()))°")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(colour(leg.tack).opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(wind.directionFrom))
                Text("\(Int(wind.directionFrom.rounded()))°")
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
            }
            .padding(8)
            .background(.regularMaterial, in: Circle())
            .padding(10)
        }
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
