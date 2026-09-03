import Charts
import OpenWaterCore
import SwiftUI

/// Fixed-distance splits: a bar per split, then the table.
///
/// The chart plots *time per split*, not speed, which is the one that reads
/// correctly at a glance — a taller bar is a slower split, and the eye finds
/// the moment a session fell apart without having to invert anything.
struct SplitsView: View {

    let session: Session

    @Environment(AppSettings.self) private var settings

    @State private var interval: Interval = .one

    /// This screen's own idea of a distance unit.
    ///
    /// A split is the one place the unit *is* the analysis — "best km" and
    /// "best nautical mile" are different questions, and a rider comparing
    /// against a friend's app should not have to leave for Settings to ask
    /// the other one. Starts on the app-wide unit and moves freely; nothing
    /// here writes back to Settings.
    @State private var unitOverride: DistanceUnit?

    private var unit: DistanceUnit { unitOverride ?? settings.units.distance }

    enum Interval: Double, CaseIterable, Identifiable {
        case quarter = 0.25
        case half = 0.5
        case one = 1
        case five = 5

        var id: Double { rawValue }

        func label(_ unit: DistanceUnit) -> String {
            let number = rawValue < 1
                ? String(format: "%g", rawValue)
                : String(format: "%.0f", rawValue)
            return "\(number) \(unit.symbol)"
        }

        func metres(_ unit: DistanceUnit) -> Double {
            rawValue * unit.metresPerUnit
        }
    }

    /// Computed once per interval and unit, off the main actor. As a
    /// computed property this walked the track on every read, and the table
    /// read it once per row.
    @State private var splits: [Split] = []

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// The fastest full split. Partials stay out: a 200 m tail is not a km.
    private var best: Split? {
        splits.filter(\.isComplete).min { $0.duration < $1.duration }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                chart
                table
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .readableContentColumn()
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Split")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · Splits")
        .task(id: interval.metres(unit)) {
            let session = session
            let metres = interval.metres(unit)
            splits = await Task.detached(priority: .userInitiated) {
                session.splits(every: metres)
            }.value
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Interval", selection: $interval) {
                        ForEach(Interval.allCases) { option in
                            Text(option.label(unit)).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(interval.label(unit))
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }

                Spacer(minLength: 8)

                // km · NM · mi, right here. The one screen where the unit is
                // the question being asked.
                Picker("Unit", selection: Binding(
                    get: { unit },
                    set: { unitOverride = $0 }
                )) {
                    ForEach(DistanceUnit.allCases, id: \.self) { u in
                        Text(u.symbol).tag(u)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
            }

            if let best {
                HStack(spacing: 6) {
                    Text("BEST")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.harbourNavy)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 4))
                    Text("\(interval.label(unit)) in \(Format.duration(best.duration))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("· \(Format.speed(best.averageSpeed, unit: settings.units.speed, decimals: 1)) avg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if splits.isEmpty {
                Text("This session is too short to split.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 120)
            } else {
                Chart(splits) { split in
                    BarMark(
                        x: .value("Split", split.number),
                        y: .value("Time", split.duration)
                    )
                    .foregroundStyle(
                        split.number == best?.number ? Color.harbourNavy
                        : split.isComplete ? Color.accentColor
                        : Color.foam
                    )
                    .cornerRadius(3)
                }
                .chartXAxis {
                    // Numeric rather than a category per bar, so the axis can
                    // thin its own labels: thirty of them on a phone is a grey
                    // smear, and a category axis draws every one.
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisValueLabel {
                            if let number = value.as(Int.self) {
                                Text("\(number)").font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(Format.duration(seconds))
                            }
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Table

    private var table: some View {
        VStack(spacing: 0) {
            ForEach(splits) { split in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(unit.symbol) \(split.number)")
                                .font(.title3.weight(.bold))
                            if split.number == best?.number {
                                Text("BEST")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(Color.harbourNavy)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        if let heartRate = split.averageHeartRate {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(heartRate.rounded()))")
                                    .font(.subheadline)
                                    .monospacedDigit()
                            }
                        }
                        if !split.isComplete {
                            Text(Format.distance(split.distance, unit: unit))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.duration(split.duration))
                            .font(.subheadline)
                            .monospacedDigit()
                        Text("Avg speed: \(Format.speed(split.averageSpeed, unit: settings.units.speed, decimals: 1))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Speed Max: \(Format.speed(split.maxSpeed, unit: settings.units.speed, decimals: 1))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 12)

                if split.number != splits.last?.number {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}
