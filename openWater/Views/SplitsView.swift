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

    private var splits: [Split] {
        session.splits(every: interval.metres(settings.units.distance))
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Split")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(spacing: 12) {
            Menu {
                Picker("Interval", selection: $interval) {
                    ForEach(Interval.allCases) { option in
                        Text(option.label(settings.units.distance)).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(interval.label(settings.units.distance))
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
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
                    .foregroundStyle(split.isComplete ? Color.accentColor : Color.accentColor.opacity(0.45))
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
                        Text("\(settings.units.distance.symbol) \(split.number)")
                            .font(.title3.weight(.bold))
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
                            Text(Format.distance(split.distance, unit: settings.units.distance))
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
