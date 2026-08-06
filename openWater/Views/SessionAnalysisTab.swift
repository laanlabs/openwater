import OpenWaterCore
import SwiftUI

/// The contents page for everything a rider digs into after the fact.
///
/// These cards used to be scattered: Upwind, Turns, Foiling, Downwind, Health
/// and GPS quality stacked eight deep at the bottom of Summary, Polar and
/// Angles on a separate Charts tab, Splits behind a gradient capsule. Each was
/// reasonable on its own and the set was unreadable — the complaint was never
/// that a number was missing, it was that nothing could be found.
///
/// So: one row per topic, each carrying its own headline so the top line is
/// readable without tapping anything, and a screen behind it with room to
/// breathe. A row only appears when the session actually has that data, which
/// is the same rule Summary used — a flat-water session has no glides and
/// should not be offered a glides screen.
struct SessionAnalysisTab: View {

    /// Optional so the tab can be previewed without a database row; the
    /// route name is the only thing that needs it.
    var stored: StoredSession?
    let session: Session
    let summary: SessionSummary

    var onSetWind: () -> Void = {}
    var onEdit: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    var body: some View {
        List {
            if showsRoute { routeSection }
            if showsWindSection { windSection }
            speedSection
            if showsTechniqueSection { techniqueSection }
            sessionSection
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
    }

    // MARK: - Route

    /// Only when there is a route worth naming.
    ///
    /// Two gates, and the second was learned the hard way. The session has to
    /// have gone somewhere — no "at one spot" row on every lap session, on a
    /// screen whose whole job is cutting noise. And it has to have a *name*:
    /// a row reading "Downwinder · 7 m" says nothing the map does not, and the
    /// net displacement of a session that came back to its launch is not a
    /// figure anybody wants as a headline. Names arrive asynchronously, so the
    /// row appears when the lookup lands rather than sitting there empty.
    private var routeSection: some View {
        Section("Route") {
            HStack(spacing: 12) {
                Image(systemName: summary.shape.kind == .downwinder
                      ? "arrow.down.right.circle" : "arrow.right.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(routeName ?? summary.shape.kind.displayName)
                        .lineLimit(2)
                    if let detail = routeDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(routeDistance)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var showsRoute: Bool {
        summary.shape.isPointToPoint && routeName != nil
    }

    private var routeName: String? { stored?.routeName }

    /// Distance covered, not distance displaced. On a shuttle day the net
    /// displacement is one leg's worth and on any run it undersells the
    /// riding; "how far did I go" is the question this answers.
    private var routeDistance: String {
        Format.distance(summary.distance, unit: settings.units.distance)
    }

    private var routeDetail: String? {
        var parts: [String] = [summary.shape.kind.displayName]
        if let alignment = summary.shape.downwindAlignment, summary.shape.kind == .downwinder {
            parts.append("\(Int(alignment.rounded()))° off dead downwind")
        }
        let legs = summary.shape.legs.count
        if legs > 1 { parts.append("\(legs) runs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Wind

    /// An upwind row needs a polar with something upwind in it; the angles
    /// screen is offered to any wind-powered sport, because when there is no
    /// polar it is the screen that explains why and offers the fix.
    private var upwindPolar: PolarAnalysis? {
        guard let polar = summary.polar,
              polar.beat != nil
                || polar.upwindAngle(.port) != nil
                || polar.upwindAngle(.starboard) != nil
        else { return nil }
        return polar
    }

    private var showsWindSection: Bool {
        session.sport.isWindPowered || summary.polar != nil
    }

    @ViewBuilder
    private var windSection: some View {
        Section("Wind") {
            if let polar = upwindPolar {
                AnalysisRow(symbol: "arrow.up.right", title: "Upwind", value: upwindValue(polar)) {
                    UpwindDetailView(session: session, summary: summary, polar: polar)
                }
            }
            AnalysisRow(symbol: "chart.pie", title: "Polar & angles", value: angleValue) {
                PolarAnglesScreen(
                    session: session,
                    polar: summary.polar,
                    units: settings.units,
                    onSetWind: onSetWind
                )
            }
            if windSpeedIsMissing {
                Button(action: onSetWind) {
                    HStack(spacing: 12) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("No wind speed")
                                .foregroundStyle(.primary)
                            Text("Angles are right; there is nothing to compare them against")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func upwindValue(_ polar: PolarAnalysis) -> String? {
        guard let beat = polar.beat else {
            guard let angle = polar.bestUpwindAngle else { return nil }
            return "\(Int(angle.rounded()))°"
        }
        let vmg = Format.speed(beat.vmg, unit: settings.units.speed, decimals: 1)
        guard let angle = beat.meanAngle else { return vmg }
        return "\(vmg) @ \(Int(angle.rounded()))°"
    }

    private var angleValue: String? {
        guard let polar = summary.polar else { return "not set" }
        guard let tacking = polar.tackingAngle else {
            return Format.cardinal(polar.wind.directionFrom)
        }
        return "tacks \(Int(tacking.rounded()))°"
    }

    /// Direction without strength — say so on the contents page rather than
    /// making the rider open a screen to find out.
    private var windSpeedIsMissing: Bool {
        guard let wind = session.effectiveWind else { return false }
        return !wind.hasSpeed
    }

    // MARK: - Speed

    private var speedSection: some View {
        Section("Speed") {
            AnalysisRow(
                symbol: "chart.xyaxis.line",
                title: "Speed & VMG",
                value: "peak \(Format.speed(summary.maxSpeed, unit: settings.units.speed, decimals: 1))"
            ) {
                SpeedVMGScreen(session: session, summary: summary, units: settings.units)
            }
            AnalysisRow(symbol: "list.number", title: "Splits", value: paceValue) {
                SplitsView(session: session)
            }
            AnalysisRow(symbol: "trophy", title: "Best speeds", value: bestSpeedValue) {
                BestSpeedsList(summary: summary, units: settings.units)
            }
        }
    }

    /// Moving time per unit distance — the number the splits screen is built
    /// around, and the reason pace is worth keeping somewhere.
    private var paceValue: String? {
        let distance = summary.distance / settings.units.distance.metresPerUnit
        guard distance > 0.01, summary.movingTime > 0 else { return nil }
        let seconds = Int((summary.movingTime / distance).rounded())
        return String(format: "%d:%02d / %@", seconds / 60, seconds % 60,
                      settings.units.distance.symbol)
    }

    private var bestSpeedValue: String? {
        guard let best = summary.speedResults.filter(\.isValid).max(by: { $0.speed < $1.speed })
        else { return nil }
        return "\(Format.speed(best.speed, unit: settings.units.speed, decimals: 2)) \(best.category.shortName)"
    }

    // MARK: - Technique

    private var showsTechniqueSection: Bool {
        summary.maneuverSummary.total > 0
            || summary.foil.flightCount > 0
            || summary.jumpSummary.count > 0
            || showsDownwind
    }

    /// Glides are only worth a screen when the session was about riding swell.
    ///
    /// A count above zero is not enough. An afternoon of upwind-downwind laps
    /// turns up a handful of short glides on the downwind halves, and offering
    /// a "Downwind" screen for them puts the session's *upwind* work on a page
    /// about bumps — which is exactly what a rider reported. Either the shape
    /// of the session says it was a run, or the sport says catching swell is
    /// the point of it.
    private var showsDownwind: Bool {
        guard summary.downwind.glideCount > 0 else { return false }
        return summary.shape.kind == .downwinder || session.sport.ridesSwell
    }

    @ViewBuilder
    private var techniqueSection: some View {
        Section("Technique") {
            if summary.maneuverSummary.total > 0 {
                AnalysisRow(symbol: "arrow.triangle.2.circlepath", title: "Turns", value: turnValue) {
                    AnalysisDetail(title: "Turns") {
                        ManeuverCard(summary: summary.maneuverSummary,
                                     maneuvers: summary.maneuvers)
                            .cardChrome()
                    }
                }
            }
            if summary.foil.flightCount > 0 {
                AnalysisRow(symbol: "airplane", title: "Foiling", value: foilValue) {
                    FoilingScreen(
                        session: session,
                        summary: summary,
                        units: settings.units,
                        onEdit: onEdit
                    )
                }
            }
            if summary.jumpSummary.count > 0 {
                AnalysisRow(symbol: "arrow.up.forward", title: "Airtime", value: airtimeValue) {
                    AirtimeScreen(summary: summary, units: settings.units)
                }
            }
            if showsDownwind {
                AnalysisRow(symbol: "water.waves", title: "Downwind", value: glideValue) {
                    DownwindDetailView(session: session, summary: summary)
                }
            }
        }
    }

    private var turnValue: String? {
        let turns = summary.maneuverSummary
        guard let dry = turns.dryGybeRate else { return "\(turns.total)" }
        return "\(turns.total) · \(Int((dry * 100).rounded()))% dry"
    }

    private var foilValue: String? {
        let foil = summary.foil
        return "\(Format.shortDuration(foil.timeOnFoil)) · \(Int((foil.foilingFraction * 100).rounded()))%"
    }

    private var airtimeValue: String? {
        let jumps = summary.jumpSummary
        guard jumps.count > 0 else { return nil }
        return "\(jumps.count) · \(Format.shortDuration(jumps.bestAirtime)) best"
    }

    private var glideValue: String? {
        let count = summary.downwind.glideCount
        return "\(count) glide\(count == 1 ? "" : "s")"
    }

    // MARK: - Session

    private var hasHealthData: Bool {
        summary.averageHeartRate != nil || summary.activeEnergyKilojoules != nil
    }

    private var sessionSection: some View {
        Section("Session") {
            if hasHealthData {
                AnalysisRow(symbol: "heart", title: "Heart rate", value: heartValue) {
                    AnalysisDetail(title: "Health") {
                        HealthCard(session: session, summary: summary)
                    }
                }
            }
            AnalysisRow(symbol: "antenna.radiowaves.left.and.right",
                        title: "GPS quality",
                        value: summary.quality.grade.displayName) {
                AnalysisDetail(title: "GPS Quality") {
                    QualityCard(quality: summary.quality,
                                source: summary.speedSource,
                                sport: session.sport)
                        .cardChrome()
                }
            }
            AnalysisRow(symbol: "info.circle", title: "How these numbers were measured", value: nil) {
                MeasurementNotesView(session: session, summary: summary)
            }
        }
    }

    private var heartValue: String? {
        guard let average = summary.averageHeartRate else { return nil }
        return "\(Int(average.rounded())) avg"
    }
}

// MARK: - Pieces

/// One line of the contents page: what it is, what it says, where it goes.
private struct AnalysisRow<Destination: View>: View {

    let symbol: String
    let title: String
    let value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(title)
                    .lineLimit(1)
                if let value {
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The frame every analysis screen shares.
///
/// The cards it wraps were written to sit on Summary's grouped background and
/// carry no chrome of their own, so it supplies the background and the padding
/// and leaves each card to say what it says.
struct AnalysisDetail<Content: View>: View {

    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(14)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Screens that were the Charts tab

/// The polar and the wind angles, with their explanations given room instead
/// of being wedged between the two charts they explain.
struct PolarAnglesScreen: View {

    let session: Session
    let polar: PolarAnalysis?
    let units: UnitPreferences
    var onSetWind: () -> Void = {}

    var body: some View {
        AnalysisDetail(title: "Polar & Angles") {
            if let polar {
                PolarChart(polar: polar, units: units)
                    .cardChrome()
                AngleSummary(polar: polar, units: units)
                    .cardChrome()
            } else if session.sport.isWindPowered {
                // Silently omitting the angles leaves a rider wondering whether
                // the app has them and they are lost, or whether it never had
                // them. Say which, and offer the fix.
                NoWindCard(session: session, onSetWind: onSetWind)
                    .cardChrome()
            } else {
                // Same reasoning, different answer: this sport was never going
                // to have one.
                NoPolarCard(sport: session.sport)
                    .cardChrome()
            }
        }
    }
}

/// Speed, VMG, runs, flights and falls on one time axis.
struct SpeedVMGScreen: View {

    let session: Session
    let summary: SessionSummary
    let units: UnitPreferences

    var body: some View {
        AnalysisDetail(title: "Speed & VMG") {
            SpeedChart(session: session, summary: summary, units: units)
                .cardChrome()
        }
    }
}
