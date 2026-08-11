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

    var onSetWind: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var showingNotes = false
    @State private var showsMoreNumbers = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                conditionsCard
                headlineNumbers
                BestSpeedsCard(summary: summary, units: settings.units)

                // Upwind, Turns, Foiling, Downwind, Health and GPS quality all
                // used to stack up below this point. They are good cards and
                // they were unreadable in a column eight deep — they now have
                // a screen each, listed on the Analysis tab.
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .readableContentColumn()
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingNotes) {
            MeasurementNotesView(session: session, summary: summary)
        }
    }

    // MARK: - Conditions

    /// Wind and swell, on their own, always one tap from being set.
    ///
    /// This was a line inside the header card, and it is the single most
    /// corrected field in the app: the direction is usually a guess read off
    /// the shape of the track, the strength can never be inferred at all, and
    /// every angle, VMG figure, polar and glide is measured from one or both.
    /// A rider who wants to fix it should not have to notice that a line of
    /// text happens to be a button.
    private var conditionsCard: some View {
        Button(action: onSetWind) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Conditions") {
                    if let wind = session.effectiveWind, wind.source.isEstimate {
                        Text("estimated")
                            .font(.caption2)
                            .foregroundStyle(Color.harbourNavy)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "wind")
                        .font(.title3)
                        .foregroundStyle(conditionsAreComplete ? AnyShapeStyle(.tint)
                                                              : AnyShapeStyle(Color.harbourNavy))
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        if let wind = session.effectiveWind {
                            Text(windText(wind))
                                .font(.headline)
                            if let note = conditionsNote {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(Color.harbourNavy)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("No wind set")
                                .font(.headline)
                                .foregroundStyle(Color.harbourNavy)
                            Text("Angles, VMG, the polar and your glides are all measured from the wind. Tap to point at it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let gear = session.equipment?.headline {
                            Text(gear)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let swell = session.swellHeight, swell > 0.05 {
                            Text(session.swellDirection.map {
                                "\(Format.height(swell, unit: settings.units.distance)) swell from \(Format.cardinal($0))"
                            } ?? "\(Format.height(swell, unit: settings.units.distance)) swell")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .cardChrome()
        }
        .buttonStyle(.plain)
    }

    private var conditionsAreComplete: Bool {
        guard let wind = session.effectiveWind else { return false }
        return wind.hasSpeed && !wind.source.isEstimate
    }

    /// What is still missing or still a guess, said on the card rather than
    /// left for the rider to infer from an absent number.
    private var conditionsNote: String? {
        guard let wind = session.effectiveWind else { return nil }
        switch (wind.hasSpeed, wind.source.isEstimate) {
        case (false, true):
            return "No wind speed set, and the direction is estimated from your track"
        case (false, false):
            return "No wind speed set — tap to add it"
        case (true, true):
            return "Direction estimated from your track — tap to check it"
        case (true, false):
            return nil
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

            // "Viento → Hatchery". Only ever present when the ends really were
            // different places, so its absence means a session at one spot
            // rather than a lookup that has not happened.
            if let route = stored.routeName {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: shapeSymbol)
                        .foregroundStyle(.secondary)
                    // Two lines, not one shrunk to fit: guide names run long
                    // ("Berkeley Pier downwind route"), and a route with both
                    // ends elided to "…" tells the rider nothing.
                    Text(route)
                        .font(.subheadline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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

    private var shapeSymbol: String {
        switch summary.shape.kind {
        case .downwinder: "arrow.down.right.circle"
        case .crossing: "arrow.right.circle"
        case .aroundASpot: "mappin.and.ellipse"
        }
    }

    private func windText(_ wind: Wind) -> String {
        let direction = "\(Format.cardinal(wind.directionFrom)), \(Format.bearing(wind.directionFrom, includeCardinal: false))"
        guard let speed = wind.speed else { return direction }
        return "\(direction) · \(Format.speed(speed, unit: settings.units.speed, decimals: 0))"
    }

    // MARK: - Headline numbers

    /// Four figures, three of them fixed.
    ///
    /// This was six of equal weight, copied from the app we were measuring
    /// ourselves against. Two of them — stopped time and pace — are the
    /// questions a runner asks, and putting them in the same typeface as top
    /// speed said they mattered as much. They are a tap away now rather than
    /// gone, because the rider on a long crossing really does want pace.
    ///
    /// The fourth tile is the one that says what kind of session this was, and
    /// `HeadlineMetrics` in the core picks it: a foiler leads with time on
    /// foil, a downwinder with time gliding, everyone else with average speed.
    private var headlineNumbers: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                DetailStat(
                    title: "Speed Max",
                    colour: .harbourNavy,
                    value: Format.speed(summary.maxSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false),
                    unit: settings.units.speed.symbol
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
                    title: "Duration",
                    colour: .teal,
                    value: Format.duration(summary.duration),
                    unit: summary.duration >= 3600 ? "h:m:s" : "m:s"
                )
                sportSlotStat
            }

            moreNumbers
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var slot: HeadlineMetrics.Slot {
        HeadlineMetrics.slot(for: session.sport, summary: summary)
    }

    /// The fourth tile. Green for the two that mean "you were riding properly"
    /// — the same green the ribbon and the speed chart use for flying.
    @ViewBuilder
    private var sportSlotStat: some View {
        switch slot {
        case .timeOnFoil:
            DetailStat(
                title: slot.title,
                colour: .green,
                value: Format.duration(summary.foil.timeOnFoil),
                unit: summary.foil.timeOnFoil >= 3600 ? "h:m:s" : "m:s"
            )
        case .timeGliding:
            DetailStat(
                title: slot.title,
                colour: .green,
                value: Format.duration(summary.downwind.glideTime),
                unit: summary.downwind.glideTime >= 3600 ? "h:m:s" : "m:s"
            )
        case .averageMovingSpeed:
            // "Avg speed" unqualified reads as distance ÷ duration, and this is
            // not that — it is distance ÷ *moving* time, which on a session
            // with long drifts is twice the number. Another app showing 3.2
            // next to our 7.5 under the same word looks like one of us is
            // broken; naming it settles which question each is answering.
            DetailStat(
                title: slot.title,
                colour: .harbourNavy,
                value: Format.speed(summary.averageMovingSpeed, unit: settings.units.speed,
                                    decimals: 1, includeSymbol: false),
                unit: settings.units.speed.symbol
            )
        }
    }

    /// The numbers that are worth keeping and not worth leading with.
    private var moreNumbers: some View {
        let pause = max(0, summary.duration - summary.movingTime)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { showsMoreNumbers.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsMoreNumbers ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(showsMoreNumbers ? "Fewer numbers" : "More numbers")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showsMoreNumbers {
                VStack(spacing: 7) {
                    if slot != .averageMovingSpeed {
                        minorStat("Avg moving",
                                  Format.speed(summary.averageMovingSpeed,
                                               unit: settings.units.speed, decimals: 1))
                    }
                    // Not "Pause". Nobody paused anything — this is time spent
                    // below the sport's moving threshold, which on a light day
                    // is most of a session. An app that only counts explicit
                    // pauses shows zero here, and a rider comparing the two
                    // would take ours for a bug rather than for a different
                    // measurement.
                    minorStat("Stopped", Format.duration(pause))
                    minorStat("Pace", "\(paceText) / \(settings.units.distance.symbol)")

                    Divider()

                    // The question "why does this not match the other app?"
                    // occurs while looking at exactly these numbers.
                    Button {
                        showingNotes = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                            Text("How these numbers were measured")
                                .font(.caption)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func minorStat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
        }
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
                                .foregroundStyle(Color.harbourNavy)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.tintWash, in: RoundedRectangle(cornerRadius: 9))

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
                BestSpeedsList(summary: summary, units: units)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingList = false }
                        }
                    }
            }
        }
    }
}

/// Every category, achieved or not, with what each one means.
///
/// Lifted out of `BestSpeedsCard`'s sheet so the Analysis tab can push the
/// same list rather than growing a second copy of it.
struct BestSpeedsList: View {

    let summary: SessionSummary
    let units: UnitPreferences

    var body: some View {
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
        .feedbackButton("Session · Best Speeds")
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
