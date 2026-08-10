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

    /// Pushed when a record is tapped.
    @State private var path: [UUID] = []

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.records.isEmpty {
                    ContentUnavailableView(
                        "No records yet",
                        systemImage: "trophy",
                        description: Text("Record a session and your personal bests will appear here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(SpeedCategory.standard) { category in
                                if let holder = library.records[category] {
                                    // Tappable, because the obvious next
                                    // question about a personal best is "which
                                    // session was that?" and there was no way
                                    // to answer it.
                                    NavigationLink(value: holder.sessionID) {
                                        RecordRow(
                                            category: category,
                                            holder: holder,
                                            units: settings.units
                                        )
                                    }
                                }
                            }
                        } header: {
                            Text("Personal bests")
                        } footer: {
                            Text("Tap a record to open the session that set it.")
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
                    .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
                }
            }
            .navigationTitle("Bests")
            .feedbackButton("Bests")
            .navigationDestination(for: UUID.self) { id in
                if let stored = library.session(id: id), !stored.isDeleted {
                    SessionDetailView(stored: stored)
                } else {
                    ContentUnavailableView(
                        "Session no longer available",
                        systemImage: "questionmark.folder"
                    )
                }
            }
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
                // The full name, not the abbreviation: "NM" means nothing to
                // somebody who has not already learnt the category list.
                Text(category.displayName)
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

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

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

                            summary

                            Text(explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
                }
            }
            .navigationTitle("Trends")
            .feedbackButton("Trends")
        }
    }

    /// Best, latest, and the gap between them.
    ///
    /// A line on its own answers "am I improving?" only if you can read a
    /// gradient off two dozen points. These three numbers answer it directly,
    /// and they were also the obvious thing to put in the half-screen of white
    /// space the chart left behind.
    @ViewBuilder
    private var summary: some View {
        let values = filtered.map(value(for:))
        if let best = values.max(), let latest = values.last, values.count >= 2 {
            let previous = values.dropLast().last ?? latest
            let change = latest - previous

            HStack(alignment: .top, spacing: 0) {
                trendStat("Best", format(best), colour: .orange)
                trendStat("Latest", format(latest), colour: .blue)
                trendStat(
                    "vs previous",
                    (change >= 0 ? "+" : "") + format(change),
                    colour: change >= 0 ? .green : .secondary
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func trendStat(_ label: String, _ value: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colour)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                BigNumber(value, size: 26)
                Text(axisLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One decimal for speeds and rates, none for minutes — a chart of
    /// "63.0 minutes" is false precision.
    private func format(_ value: Double) -> String {
        switch metric {
        case .maxSpeed, .best500, .distance: String(format: "%.1f", value)
        case .foilTime, .cleanRun, .dryGybes: String(format: "%.0f", value)
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
            "Peak speed depends as much on the day's wind as on you, so it is a noisy progress signal. Time on foil, dry gybes and longest clean run track your own progress more honestly — switch metric above."
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
