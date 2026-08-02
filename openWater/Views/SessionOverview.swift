import OpenWaterCore
import SwiftUI

/// The session at a glance: what it was, the six numbers that matter, and then
/// everything the analysis found, one card at a time.
///
/// This is the screen a rider opens straight after coming in, so the order is
/// the order they care about — headline speed and distance first, splits next,
/// then the detail. The map, the runs and the charts are a tap away rather than
/// competing for the top of the screen.
struct SessionOverview: View {

    let stored: StoredSession
    let session: Session
    let summary: SessionSummary

    var onEdit: () -> Void = {}
    var onOpenMap: () -> Void = {}
    var onReplay: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var showingNotes = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                headlineNumbers

                // Directly under the numbers it explains, not buried in a
                // menu. The question "why does this not match the other app?"
                // occurs while looking at them.
                Button {
                    showingNotes = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("How these numbers were measured")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SplitsView(session: session)
                } label: {
                    HStack {
                        Text("Splits Analysis")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [.teal, .blue],
                                       startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                }

                HStack(spacing: 12) {
                    QuickAction(title: "Map", symbol: "map", action: onOpenMap)
                    QuickAction(title: "Replay", symbol: "play.fill", action: onReplay)
                }

                BestSpeedsCard(summary: summary, units: settings.units)

                if summary.maneuverSummary.total > 0 {
                    ManeuverCard(summary: summary.maneuverSummary)
                }
                if summary.foil.flightCount > 0 {
                    FoilSummaryCard(
                        foil: summary.foil,
                        falls: summary.fallSummary,
                        units: settings.units,
                        totalDistance: summary.distance,
                        takeoffThreshold: session.effectiveFoilTakeoffSpeed,
                        onChangeThreshold: onEdit
                    )
                }
                if summary.downwind.glideCount > 0 {
                    DownwindCard(downwind: summary.downwind, units: settings.units)
                }
                HealthCard(session: session, summary: summary)
                QualityCard(quality: summary.quality, source: summary.speedSource, sport: session.sport)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingNotes) {
            MeasurementNotesView(session: session, summary: summary)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No title here: the navigation bar already says it, and printing
            // it twice a centimetre apart just costs a line of screen.
            HStack(spacing: 6) {
                Text(session.startDate.formatted(
                    .dateTime.weekday(.wide).month(.abbreviated).day().year().hour().minute()
                ))
                .font(.headline)
                if let device = session.deviceModel, device.localizedCaseInsensitiveContains("watch") {
                    Image(systemName: "applewatch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Tappable: an estimated wind is the field riders most often want
            // to correct, and every angle on the Charts tab is measured from it.
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Image(systemName: "wind")
                        .foregroundStyle(.secondary)
                    if let wind = session.effectiveWind {
                        Text(windText(wind))
                            .font(.subheadline)
                        if wind.source != .manual {
                            Text("estimated")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    } else {
                        Text("Set the wind")
                            .font(.subheadline)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if session.purpose != nil || session.feeling != nil {
                HStack {
                    if let purpose = session.purpose {
                        Text(purpose)
                            .font(.subheadline)
                    }
                    Spacer()
                    if let feeling = session.feeling {
                        HStack(spacing: 5) {
                            Text("Feeling:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Image(systemName: Feeling.symbol(for: feeling))
                                .font(.title3)
                                .foregroundStyle(Feeling.colour(for: feeling))
                        }
                    }
                }
            }

            if !session.notes.isEmpty {
                Text(session.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func windText(_ wind: Wind) -> String {
        let direction = "\(Format.cardinal(wind.directionFrom)), \(Format.bearing(wind.directionFrom, includeCardinal: false))"
        guard let speed = wind.speed else { return direction }
        return "\(direction) · \(Format.speed(speed, unit: settings.units.speed, decimals: 0))"
    }

    // MARK: - Headline numbers

    /// The six figures the reference app leads with, in the same order. Pause
    /// and pace are the two people forget they want until they are missing:
    /// pause explains a distance that looks slow, and pace is how anyone doing
    /// a long crossing thinks about progress.
    private var headlineNumbers: some View {
        let pause = max(0, summary.duration - summary.movingTime)
        return VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                DetailStat(
                    title: "Speed Max",
                    colour: .orange,
                    value: Format.speed(summary.maxSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false),
                    unit: settings.units.speed.symbol
                )
                DetailStat(
                    title: "Avg speed",
                    colour: .orange,
                    value: Format.speed(summary.averageMovingSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false),
                    unit: settings.units.speed.symbol
                )
            }
            HStack(alignment: .top, spacing: 0) {
                DetailStat(
                    title: "Duration",
                    colour: .teal,
                    value: Format.duration(summary.duration),
                    unit: summary.duration >= 3600 ? "h:m:s" : "m:s"
                )
                DetailStat(
                    title: "Distance",
                    colour: .blue,
                    value: Format.distance(summary.distance, unit: settings.units.distance,
                                           includeSymbol: false),
                    unit: settings.units.distance.symbol
                )
            }
            HStack(alignment: .top, spacing: 0) {
                DetailStat(
                    title: "Pause",
                    colour: .secondary,
                    value: Format.duration(pause),
                    unit: pause >= 3600 ? "h:m:s" : "m:s"
                )
                DetailStat(
                    title: "Pace",
                    colour: .secondary,
                    value: paceText,
                    unit: "/ \(settings.units.distance.symbol)"
                )
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Moving time per unit distance, `mm:ss`.
    private var paceText: String {
        let distance = summary.distance / settings.units.distance.metresPerUnit
        guard distance > 0.01, summary.movingTime > 0 else { return "—" }
        let seconds = Int((summary.movingTime / distance).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Pieces

/// How a session felt, as a face.
enum Feeling {
    static let all = [1, 2, 3, 4, 5]

    static func symbol(for value: Int) -> String {
        switch value {
        case 1: "cloud.rain"
        case 2: "face.dashed"
        case 3: "face.smiling.inverse"
        case 4: "hand.thumbsup"
        case 5: "star.fill"
        default: "face.smiling"
        }
    }

    static func label(for value: Int) -> String {
        switch value {
        case 1: "Rough"
        case 2: "Meh"
        case 3: "OK"
        case 4: "Good"
        case 5: "Epic"
        default: "OK"
        }
    }

    static func colour(for value: Int) -> Color {
        switch value {
        case 1: .gray
        case 2: .secondary
        case 3: .blue
        case 4: .green
        case 5: .orange
        default: .blue
        }
    }
}

/// Common session purposes, offered rather than imposed.
enum SessionPurpose {
    static let suggestions = ["For fun", "Training", "Race", "Coaching", "Testing gear", "Downwinder"]
}

struct DetailStat: View {
    let title: String
    let colour: Color
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colour)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                BigNumber(value, size: 30)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuickAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// The speed categories as a row of chips, the way a speed sailor reads them.
struct BestSpeedsCard: View {

    let summary: SessionSummary
    let units: UnitPreferences

    @State private var showingList = false

    private var achieved: [SpeedResult] {
        summary.speedResults.filter(\.isValid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Best Speeds", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                if !achieved.isEmpty {
                    Button("Show List") { showingList = true }
                        .font(.subheadline)
                }
            }

            if achieved.isEmpty {
                Text("This session was too short for any of the standard categories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(achieved, id: \.category) { result in
                            VStack(spacing: 4) {
                                HStack(spacing: 3) {
                                    Text(result.category.shortName)
                                        .font(.subheadline.weight(.semibold))
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

                                Text(Format.speed(result.speed, unit: units.speed, decimals: 2))
                                    .font(.subheadline)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showingList) {
            NavigationStack {
                List(summary.speedResults, id: \.category) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.category.displayName)
                            Text(result.category.explanation)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(result.isValid
                             ? Format.speed(result.speed, unit: units.speed)
                             : "—")
                        .monospacedDigit()
                        .foregroundStyle(result.isValid ? .primary : .secondary)
                    }
                }
                .navigationTitle("Best Speeds")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingList = false }
                    }
                }
            }
        }
    }
}

/// Heart rate and energy, when the watch recorded them.
struct HealthCard: View {

    let session: Session
    let summary: SessionSummary

    private var minimumHeartRate: Double? {
        session.track.points.compactMap(\.heartRate).min()
    }

    var body: some View {
        if summary.averageHeartRate != nil || summary.activeEnergyKilojoules != nil {
            VStack(alignment: .leading, spacing: 10) {
                Label("Health", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if let minimum = minimumHeartRate {
                    row("Heart Rate Min", "\(Int(minimum.rounded()))", symbol: "heart")
                }
                if let maximum = summary.maxHeartRate {
                    row("Heart Rate Max", "\(Int(maximum.rounded()))", symbol: "heart")
                }
                if let average = summary.averageHeartRate {
                    row("Heart Rate Avg", "\(Int(average.rounded()))", symbol: "heart")
                }
                if let energy = summary.activeEnergyKilojoules {
                    // Kilojoules are what HealthKit hands over; riders read
                    // calories, so the conversion happens here rather than
                    // being smuggled into the model.
                    row("Calories", "\(Int((energy / 4.184).rounded()))", symbol: nil)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func row(_ title: String, _ value: String, symbol: String?) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
