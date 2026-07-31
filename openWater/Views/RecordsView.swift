import Charts
import OpenWaterCore
import SwiftData
import SwiftUI

/// The record book.
struct RecordsView: View {

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings

    @Query(sort: \StoredSession.startDate, order: .reverse)
    private var sessions: [StoredSession]

    var body: some View {
        NavigationStack {
            Group {
                if library.records.isEmpty {
                    ContentUnavailableView(
                        "No records yet",
                        systemImage: "trophy",
                        description: Text("Record a session and your personal bests will appear here.")
                    )
                } else {
                    List {
                        Section("Personal bests") {
                            ForEach(SpeedCategory.standard) { category in
                                if let holder = library.records[category] {
                                    RecordRow(
                                        category: category,
                                        holder: holder,
                                        units: settings.units
                                    )
                                }
                            }
                        }

                        if let foiling = bestFoiling {
                            Section("Foiling") {
                                LabeledContent(
                                    "Longest clean run",
                                    value: Format.duration(foiling.longestCleanStreak)
                                )
                                LabeledContent(
                                    "Most time on foil",
                                    value: Format.duration(foiling.timeOnFoil)
                                )
                                LabeledContent(
                                    "Best dry-gybe rate",
                                    value: "\(Int(bestDryGybeRate * 100))%"
                                )
                            }
                        }

                        Section("Totals") {
                            LabeledContent("Sessions", value: "\(sessions.count)")
                            LabeledContent(
                                "Distance",
                                value: Format.distance(
                                    sessions.reduce(0) { $0 + $1.distance },
                                    unit: settings.units.distance
                                )
                            )
                            LabeledContent(
                                "Time on the water",
                                value: Format.duration(sessions.reduce(0) { $0 + $1.movingTime })
                            )
                        }
                    }
                }
            }
            .navigationTitle("Records")
        }
    }

    private var bestFoiling: StoredSession? {
        sessions.max { $0.longestCleanStreak < $1.longestCleanStreak }
    }

    private var bestDryGybeRate: Double {
        sessions.filter { $0.gybeCount >= 3 }.map(\.dryGybeRate).max() ?? 0
    }
}

struct RecordRow: View {

    let category: SpeedCategory
    let holder: SessionLibrary.RecordHolder
    let units: UnitPreferences

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(category.shortName)
                    .font(.subheadline.weight(.medium))
                Text(holder.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.speed(holder.speed, unit: units.speed, decimals: 2))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
}

// MARK: - Trends

/// Progression over time.
///
/// Speed is the obvious metric and the least interesting one for a foiler —
/// it plateaus quickly. The metrics that keep moving are time on foil, dry-gybe
/// rate and longest clean run, so those get equal billing.
struct TrendsView: View {

    @Environment(AppSettings.self) private var settings

    @Query(sort: \StoredSession.startDate)
    private var sessions: [StoredSession]

    @State private var sport: Sport?
    @State private var metric: Metric = .maxSpeed

    enum Metric: String, CaseIterable, Identifiable {
        case maxSpeed = "Max speed"
        case best500 = "Best 500 m"
        case foilTime = "Time on foil"
        case dryGybes = "Dry gybes"
        case cleanRun = "Longest clean run"
        case distance = "Distance"

        var id: String { rawValue }
    }

    private var filtered: [StoredSession] {
        guard let sport else { return sessions }
        return sessions.filter { $0.sport == sport }
    }

    private var availableSports: [Sport] {
        Array(Set(sessions.map(\.sport))).sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.count < 2 {
                    ContentUnavailableView(
                        "Not enough sessions",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Trends appear once you have recorded a couple of sessions.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Metric", selection: $metric) {
                                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)

                            if availableSports.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        FilterChip(title: "All", isOn: sport == nil) { sport = nil }
                                        ForEach(availableSports) { s in
                                            FilterChip(
                                                title: s.displayName,
                                                systemImage: s.symbolName,
                                                isOn: sport == s
                                            ) { sport = sport == s ? nil : s }
                                        }
                                    }
                                }
                            }

                            chart
                                .frame(height: 260)

                            Text(explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Trends")
        }
    }

    private var chart: some View {
        Chart {
            ForEach(filtered) { session in
                PointMark(
                    x: .value("Date", session.startDate),
                    y: .value(metric.rawValue, value(for: session))
                )
                .foregroundStyle(.tint)
            }
            ForEach(filtered) { session in
                LineMark(
                    x: .value("Date", session.startDate),
                    y: .value(metric.rawValue, value(for: session))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.tint.opacity(0.4))
            }
        }
        .chartYAxisLabel(axisLabel)
    }

    private func value(for session: StoredSession) -> Double {
        switch metric {
        case .maxSpeed: settings.units.speed.convert(fromMetresPerSecond: session.maxSpeed)
        case .best500: settings.units.speed.convert(fromMetresPerSecond: session.best500m)
        case .foilTime: session.timeOnFoil / 60
        case .dryGybes: session.dryGybeRate * 100
        case .cleanRun: session.longestCleanStreak / 60
        case .distance: session.distance / 1000
        }
    }

    private var axisLabel: String {
        switch metric {
        case .maxSpeed, .best500: settings.units.speed.symbol
        case .foilTime, .cleanRun: "minutes"
        case .dryGybes: "%"
        case .distance: "km"
        }
    }

    private var explanation: String {
        switch metric {
        case .maxSpeed:
            "Peak speed depends as much on the day's wind as on you, so it is a noisy progress signal. The metrics below it move more honestly."
        case .best500:
            "A 500 m average is far harder to fluke than a peak, which makes it a better measure of real speed."
        case .foilTime:
            "How much of each session you spent flying rather than getting going."
        case .dryGybes:
            "The share of gybes you came out of still on the foil. This is the number that tracks skill most directly."
        case .cleanRun:
            "Your longest unbroken stretch without going in. It climbs long after top speed has stopped moving."
        case .distance:
            "Distance covered per session."
        }
    }
}
