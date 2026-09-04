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
    /// See `SessionDetailView.revision`. Passed through to every screen that
    /// keeps its own copy of the session.
    var revision: Int = 0

    var onSetWind: () -> Void = {}
    /// Take the wind as the swell — see `SessionDetailView.useWindForSwell`.
    var onUseWindForSwell: () -> Void = {}
    var onEdit: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// What a re-find depends on: the arrow the rides are measured from, and
    /// the rules they are measured by.
    private struct WaveKey: Equatable {
        let swell: Double?
        let thresholds: SportThresholds
    }

    /// The waves ridden, worked out once for the row's headline. Not stored
    /// on the summary: wave rides are a reading of the track against the
    /// swell the rider set, and re-reading here means the row updates the
    /// moment the swell does, with no analysis version to bump.
    @State private var waves: WaveRideSummary?

    var body: some View {
        List {
            if showsRoute { routeSection }
            if showsWindSection { windSection }
            speedSection
            if showsTechniqueSection { techniqueSection }
            wavesSection
            sessionSection
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .readableContentColumn()
        // Keyed on the rules as well as the swell, exactly as the Wave Rides
        // screen is. On the swell alone, a rider who changed a rule in the
        // wave sheet came back to a row still showing the old count while the
        // screen behind it showed the new one.
        .task(id: WaveKey(swell: session.swellDirection,
                          thresholds: settings.thresholds(for: session.sport))) {
            guard let swellFrom = session.swellDirection else {
                waves = nil
                return
            }
            // Off the main actor: several linear passes over the whole track,
            // and this one runs on the way into the tab.
            let track = session.track
            let flights = summary.flights
            let sport = session.sport
            let rules = settings.thresholds(for: sport)
            waves = await Task.detached(priority: .userInitiated) {
                WaveRideFinder.forSport(sport, thresholds: rules)
                    .rides(in: track, flights: flights, swellFrom: swellFrom)
            }.value
        }
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
            AnalysisRow(symbol: "arrow.up.right", title: "Upwind",
                        value: upwindValue, warning: windWarning) {
                if let polar = upwindPolar {
                    UpwindDetailView(session: session, summary: summary, polar: polar, revision: revision)
                } else {
                    NothingFoundScreen(
                        title: "Upwind",
                        headline: "No upwind legs in this session",
                        detail: upwindExplanation,
                        session: session,
                        summary: summary,
                        needs: session.sport.isWindPowered ? [.windDirection, .windSpeed] : [],
                        onSetWind: onSetWind
                    )
                }
            }
            AnalysisRow(symbol: "chart.pie", title: "Polar & angles",
                        value: angleValue, warning: windWarning) {
                PolarAnglesScreen(
                    session: session,
                    summary: summary,
                    units: settings.units,
                    revision: revision,
                    onSetWind: onSetWind
                )
            }
            if windSpeedIsMissing {
                Button(action: onSetWind) {
                    HStack(spacing: 12) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.subheadline)
                            .foregroundStyle(Color.harbourNavy)
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

    private var upwindValue: String? {
        guard let polar = upwindPolar else { return "none found" }
        guard let beat = polar.beat else {
            guard let angle = polar.bestUpwindAngle else { return "none found" }
            return "\(Int(angle.rounded()))°"
        }
        let vmg = Format.speed(beat.vmg, unit: settings.units.speed, decimals: 1)
        guard let angle = beat.meanAngle else { return vmg }
        return "\(vmg) @ \(Int(angle.rounded()))°"
    }

    /// Why there is nothing, in the order a rider would ask.
    private var upwindExplanation: String {
        guard session.sport.isWindPowered else {
            return "Upwind legs are measured against the wind, and \(session.sport.displayName.lowercased()) is not sailed to it."
        }
        guard session.effectiveWind != nil else {
            return "An upwind leg is continuous sailing on one tack above a beam reach, which needs a wind direction to measure against. Set one and this will fill in."
        }
        return "An upwind leg is continuous sailing on one tack above a beam reach, for long enough to mean it. Nothing in this session was — a downwind run has no upwind in it, which is not a fault. The minimums are adjustable below."
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

    /// What to say on a row whose numbers are measured from the wind.
    ///
    /// An estimated direction is worth flagging as loudly as a missing one.
    /// It is a guess from the shape of the track, every angle on those screens
    /// is measured from it, and a rider who has not been told will read the
    /// numbers as fact.
    private var windWarning: String? {
        guard let wind = session.effectiveWind else {
            return "Set a wind direction — nothing here has one to measure from"
        }
        if wind.source.isEstimate {
            return wind.hasSpeed
                ? "Wind direction estimated from your track — worth checking"
                : "Wind estimated from your track, and no speed set"
        }
        return wind.hasSpeed ? nil : "No wind speed set"
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

    /// Always. A row that vanishes when its count is zero is indistinguishable
    /// from a feature that does not exist, and a rider who jumped and sees no
    /// Airtime row cannot tell whether we failed to detect it or they never
    /// left the water.
    private var showsTechniqueSection: Bool { true }

    /// Downwind is always offered, even with nothing to show.
    ///
    /// It was briefly hidden when a session had no glides worth the name, and
    /// that reads as the app having failed rather than as the water having
    /// been flat. A rider cannot tell an absent row from an unwritten feature.
    /// The same reasoning already governs the no-wind and no-polar cards: say
    /// which it is, and say why.
    private var showsDownwind: Bool { true }

    @ViewBuilder
    private var techniqueSection: some View {
        Section("Technique") {
            AnalysisRow(symbol: "arrow.triangle.2.circlepath", title: "Turns", value: turnValue) {
                TurnsScreen(session: session, summary: summary, revision: revision, onSetWind: onSetWind)
            }
            if session.sport.isFoiling {
                AnalysisRow(symbol: "airplane", title: "Foiling", value: foilValue) {
                    FoilingScreen(
                        session: session,
                        summary: summary,
                        units: settings.units,
                        revision: revision,
                        onEdit: onEdit
                    )
                }
                AnalysisRow(symbol: "arrow.up.forward", title: "Airtime", value: airtimeValue) {
                    AirtimeScreen(session: session, summary: summary, units: settings.units, revision: revision)
                }
            }
            if showsDownwind {
                AnalysisRow(symbol: "water.waves", title: "Downwind",
                            value: glideValue, warning: windWarning) {
                    DownwindDetailView(session: session, summary: summary, revision: revision, onSetWind: onSetWind)
                }
            }
        }
    }

    private var turnValue: String? {
        let turns = summary.maneuverSummary
        guard turns.total > 0 else { return "none found" }
        guard let dry = turns.dryGybeRate else { return "\(turns.total)" }
        return "\(turns.total) · \(Int((dry * 100).rounded()))% dry"
    }

    private var foilValue: String? {
        let foil = summary.foil
        guard foil.flightCount > 0 else { return "none found" }
        return "\(Format.shortDuration(foil.timeOnFoil)) · \(Int((foil.foilingFraction * 100).rounded()))%"
    }

    private var airtimeValue: String? {
        let jumps = summary.jumpSummary
        guard jumps.count > 0 else { return "none found" }
        return "\(jumps.count) · \(Format.shortDuration(jumps.bestAirtime)) best"
    }

    /// The row says what the screen behind it is about: downwind runs, from
    /// the same grouping the screen and the Runs tab use.
    private var glideValue: String? {
        let runs = GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
            .filter { $0.kind == .downwind }
        guard !runs.isEmpty else { return "none found" }
        if runs.count == 1 {
            return Format.distance(runs[0].distance, unit: settings.units.distance)
        }
        return "\(runs.count) runs"
    }

    // MARK: - Waves

    /// Always offered, same reasoning as Downwind: a row that vanishes reads
    /// as a failure, and the row itself is where a rider learns the feature
    /// wants the swell direction.
    private var wavesSection: some View {
        Section("Waves") {
            AnalysisRow(symbol: "figure.surfing", title: "Wave rides",
                        value: waveValue, warning: swellWarning) {
                WaveDetailView(session: session, summary: summary,
                               onSetWind: onSetWind, onUseWindForSwell: onUseWindForSwell)
            }
        }
    }

    /// Wave rides are measured against the swell, deliberately not the wind —
    /// a wave day is exactly the day the two disagree — so it is the swell
    /// this row asks for: the direction to find the rides at all, and the
    /// height so the day has a size.
    private var swellWarning: String? {
        if session.swellDirection == nil {
            return "Set the swell direction — waves are read from it, not the wind"
        }
        if (session.swellHeight ?? 0) <= 0.05 {
            return "Set the swell height — the size is half the story"
        }
        return nil
    }

    private var waveValue: String? {
        guard session.swellDirection != nil else { return nil }
        guard let waves else { return nil }
        guard waves.count > 0 else { return "none found" }
        return "\(waves.count) · longest \(Format.shortDuration(waves.longest?.duration ?? 0))"
    }

    // MARK: - Session

    private var hasHealthData: Bool {
        summary.averageHeartRate != nil || summary.activeEnergyKilojoules != nil
    }

    /// A watch session with no beat anywhere in it.
    ///
    /// The row used to be absent, which is the wrong absence: a rider who
    /// wore the watch for three hours reads "no heart rate row" as "this app
    /// does not do heart rate", when what happened is that the Health prompt
    /// at the first session was declined and HealthKit never says so. The row
    /// stays, wearing the warning, and the screen behind it says where to
    /// turn it back on.
    private var heartRateMissing: Bool {
        guard summary.averageHeartRate == nil,
              let device = session.deviceModel?.lowercased(),
              device.contains("watch")
        else { return false }
        return !session.track.points.contains { $0.heartRate != nil }
    }

    private var sessionSection: some View {
        Section("Session") {
            if hasHealthData || heartRateMissing {
                AnalysisRow(
                    symbol: "heart",
                    title: "Heart rate",
                    value: heartRateMissing ? "none" : heartValue,
                    warning: heartRateMissing ? "The watch was not given permission to read it" : nil
                ) {
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

    /// Set when this row's numbers rest on something the session has not got.
    /// Marked here rather than only on the screen behind it, so a rider can see
    /// from the contents page which entries are running on a guess.
    var warning: String?

    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: warning == nil ? symbol : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(warning == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let warning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        .readableContentColumn()
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · \(title)")
    }
}

// MARK: - Screens that were the Charts tab

/// The polar and the wind angles, with their explanations given room instead
/// of being wedged between the two charts they explain.
struct PolarAnglesScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    let units: UnitPreferences
    var onSetWind: () -> Void = {}

    /// The parent's copy and its revision — see `SessionDetailView.revision`.
    /// Local state above lets this screen re-analyse in place; a new revision
    /// means the parent re-read the session, and the local copy yields to it.
    private let incoming: (session: Session, summary: SessionSummary)
    var revision: Int = 0

    init(session: Session, summary: SessionSummary, units: UnitPreferences,
         revision: Int = 0, onSetWind: @escaping () -> Void = {}) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        incoming = (session, summary)
        self.units = units
        self.revision = revision
        self.onSetWind = onSetWind
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    var body: some View {
        polarAndAngles
            .onChange(of: revision) { _, _ in
                session = incoming.session
                summary = incoming.summary
            }
    }

    private var polarAndAngles: some View {
        AnalysisDetail(title: "Polar & Angles") {
            if let polar = summary.polar {
                PolarChart(polar: polar, units: units)
                    .cardChrome()
                AngleSummary(polar: polar, units: units)
                    .cardChrome()
            } else if !session.sport.isWindPowered {
                // This sport was never going to have one.
                NoPolarCard(sport: session.sport)
                    .cardChrome()
            }

            AnalysisFooter(
                session: session,
                summary: summary,
                // The whole screen is measured from the wind. Without a
                // direction there is nothing here at all, which the notice
                // says rather than leaving a blank page.
                needs: session.sport.isWindPowered ? [.windDirection, .windSpeed] : [],
                isBusy: isRecomputing,
                onSetWind: onSetWind,
                onReanalyse: reanalyse
            )
        }
    }

    private func reanalyse() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary {
                session = edited
                summary = newSummary
            }
            isRecomputing = false
        }
    }
}

/// Turns, and how sharp a change of direction has to be to be one.
struct TurnsScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    var onSetWind: () -> Void = {}

    /// The parent's copy and its revision — see `SessionDetailView.revision`.
    /// Local state above lets this screen re-analyse in place; a new revision
    /// means the parent re-read the session, and the local copy yields to it.
    private let incoming: (session: Session, summary: SessionSummary)
    var revision: Int = 0

    init(session: Session, summary: SessionSummary, revision: Int = 0,
         onSetWind: @escaping () -> Void = {}) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        incoming = (session, summary)
        self.revision = revision
        self.onSetWind = onSetWind
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    var body: some View {
        turns
            .onChange(of: revision) { _, _ in
                session = incoming.session
                summary = incoming.summary
            }
    }

    private var turns: some View {
        AnalysisDetail(title: "Turns") {
            TacksAndGybesCard(summary: summary.maneuverSummary,
                              maneuvers: summary.maneuvers,
                              units: settings.units)
            ManeuverCard(summary: summary.maneuverSummary, maneuvers: summary.maneuvers)
                .cardChrome()

            AnalysisFooter(
                session: session,
                summary: summary,
                // Telling a tack from a gybe is the one thing here that needs
                // the wind; the count and the scores do not.
                needs: session.sport.isWindPowered ? [.windDirection] : [],
                isBusy: isRecomputing,
                onSetWind: onSetWind,
                onReanalyse: reanalyse
            ) {
                ThresholdSlider(
                    title: "A turn changes heading by",
                    value: settings.thresholdBinding(for: session.sport, \.maneuverHeadingChange,
                                                     default: session.sport.thresholds.maneuverHeadingChange),
                    range: 40...170, step: 5,
                    format: { "\(Int($0))°" },
                    note: "Below this it is a course correction rather than a turn. Raise it if wobbles are being counted; lower it if real gybes are being missed.",
                    onCommit: reanalyse
                )
            }
        }
    }

    private func reanalyse() {
        isRecomputing = true
        Task {
            if let edited = await SessionReanalyser.reanalyse(session, settings: settings, library: library),
               let newSummary = edited.summary {
                session = edited
                summary = newSummary
            }
            isRecomputing = false
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
