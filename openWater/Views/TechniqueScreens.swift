import OpenWaterCore
import SwiftUI

// MARK: - Airtime

/// Jumps, which the app has always detected and never shown.
///
/// `JumpDetector` finds them from free-fall in the accelerometer and fills in
/// airtime, height, takeoff and landing speed and a confidence for every one —
/// and until now the only place any of it surfaced was `Settings`, which told
/// riders we detect "flights, gybes, falls, jumps". We displayed three of the
/// four.
///
/// Height is the number to be careful with. It comes from hangtime under
/// gravity (`g·t²/8`), which assumes you land at the height you left — off a
/// wave into a trough that is optimistic. It is labelled an estimate here for
/// the same reason the detector's own comment says so.
struct AirtimeScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    let units: UnitPreferences

    init(session: Session, summary: SessionSummary, units: UnitPreferences) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        self.units = units
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    private var jumps: [Jump] {
        summary.jumps.sorted { $0.airtime > $1.airtime }
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

    var body: some View {
        AnalysisDetail(title: "Airtime") {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Jumps")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    SummaryTile(label: "Jumps", value: "\(summary.jumpSummary.count)")
                    SummaryTile(label: "Best airtime",
                                value: Format.shortDuration(summary.jumpSummary.bestAirtime))
                    SummaryTile(label: "Best height",
                                value: Format.height(summary.jumpSummary.bestHeight, unit: units.distance))
                    SummaryTile(label: "Total airtime",
                                value: Format.shortDuration(summary.jumpSummary.totalAirtime))
                }

                Text("Height is estimated from hangtime, which assumes you land at the height you took off from. Off a wave into a trough it reads high.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .cardChrome()

            if !jumps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Every jump") {
                        Text("biggest first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(jumps.enumerated()), id: \.element.id) { position, jump in
                            if position > 0 { Divider() }
                            jumpRow(jump)
                        }
                    }
                }
                .cardChrome()
            }

            AnalysisFooter(
                session: session,
                summary: summary,
                // Jumps are found from free-fall in the accelerometer. Without
                // it there are none, and there is no threshold that will help —
                // which the notice says rather than leaving a rider tuning
                // sliders against a track that cannot answer.
                needs: [.motionData],
                isBusy: isRecomputing,
                onReanalyse: reanalyse
            ) {
                ThresholdSlider(
                    title: "Shortest jump that counts",
                    value: settings.thresholdBinding(for: session.sport, \.jumpMinimumAirtime,
                                                     default: session.sport.thresholds.jumpMinimumAirtime),
                    range: 0.3...3, step: 0.1,
                    format: { String(format: "%.1f s", $0) },
                    note: "Airtime, not height. Under half a second is usually the board skipping rather than leaving.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "How still the board goes",
                    value: settings.thresholdBinding(for: session.sport, \.jumpFreeFall,
                                                     default: session.sport.thresholds.jumpFreeFall),
                    range: 1...6, step: 0.25,
                    format: { String(format: "%.2f m/s²", $0) },
                    note: "In the air the only force on the board is gravity, so the acceleration it reports collapses toward zero. Raise this to find more jumps — and more things that were not jumps.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "How hard the landing is",
                    value: settings.thresholdBinding(for: session.sport, \.jumpLandingSpike,
                                                     default: session.sport.thresholds.jumpLandingSpike),
                    range: 4...25, step: 1,
                    format: { String(format: "%.0f m/s²", $0) },
                    note: "The spike that ends a jump. A kite lands softly under canopy and wants a lower bar; a wing drops you.",
                    onCommit: reanalyse
                )
                ThresholdSlider(
                    title: "Slowest takeoff",
                    value: settings.thresholdBinding(for: session.sport, \.jumpMinimumTakeoffSpeed,
                                                     default: session.sport.thresholds.jumpMinimumTakeoffSpeed),
                    range: 0...10, step: 0.5,
                    format: { Format.speed($0, unit: units.speed, decimals: 1) },
                    note: "You cannot jump from a standstill, and this keeps a bobbing board out of the count.",
                    onCommit: reanalyse
                )
            }
        }
    }

    private func jumpRow(_ jump: Jump) -> some View {
        HStack(spacing: 10) {
            Text(Format.shortDuration(jump.airtime))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)

            Text(Format.height(jump.height, unit: units.distance))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.speed(jump.takeoffSpeed, unit: units.speed, decimals: 1, includeSymbol: false)) → \(Format.speed(jump.landingSpeed, unit: units.speed, decimals: 1))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(Int((jump.landingRetention * 100).rounded()))% kept")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ConfidenceMark(confidence: jump.confidence)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Foiling

/// The session's flights, one row each.
///
/// `summary.flights` carried distance, average and top speed, and the speeds
/// at takeoff and landing for every flight — and drew as a row of green ticks
/// on the speed chart. The ticks say *when*; this says what each one was.
struct FoilingScreen: View {

    @State private var session: Session
    @State private var summary: SessionSummary
    let units: UnitPreferences
    var onEdit: () -> Void = {}

    init(session: Session, summary: SessionSummary, units: UnitPreferences,
         onEdit: @escaping () -> Void = {}) {
        _session = State(initialValue: session)
        _summary = State(initialValue: summary)
        self.units = units
        self.onEdit = onEdit
    }

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false

    private var flights: [Flight] {
        summary.flights.sorted { $0.duration > $1.duration }
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

    var body: some View {
        AnalysisDetail(title: "Foiling") {
            FoilSummaryCard(
                foil: summary.foil,
                falls: summary.fallSummary,
                units: units,
                totalDistance: summary.distance,
                takeoffThreshold: session.effectiveFoilTakeoffSpeed,
                onChangeThreshold: onEdit
            )
            .cardChrome()

            if !flights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Every flight") {
                        Text("longest first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(flights.enumerated()), id: \.element.id) { position, flight in
                            if position > 0 { Divider() }
                            flightRow(flight)
                        }
                    }
                }
                .cardChrome()
            }

            AnalysisFooter(
                session: session,
                summary: summary,
                // Without the accelerometer a flight is a speed inference.
                needs: [.motionData],
                isBusy: isRecomputing,
                onReanalyse: reanalyse
            ) {
                ThresholdSlider(
                    title: "Flying above",
                    value: settings.thresholdBinding(for: session.sport, \.foilTakeoffSpeed,
                                                     default: session.sport.thresholds.foilTakeoffSpeed),
                    range: 2...12, step: 0.1,
                    format: { Format.speed($0, unit: units.speed, decimals: 1) },
                    note: "The speed at which your foil is carrying you. It decides time on foil, the flight count and the dry-gybe rate. Raise it if the app thinks you are flying while you are still taxiing; lower it if long glides are being missed.",
                    onCommit: reanalyse
                )
            }
        }
    }

    private func flightRow(_ flight: Flight) -> some View {
        HStack(spacing: 10) {
            Text(Format.shortDuration(flight.duration))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 56, alignment: .leading)

            Text(Format.distance(flight.distance, unit: units.distance))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Format.speed(flight.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(flight.maxSpeed, unit: units.speed, decimals: 1, includeSymbol: false)) top")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("up at \(Format.speed(flight.takeoffSpeed, unit: units.speed, decimals: 1))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ConfidenceMark(confidence: flight.confidence)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Confidence

/// Says when a detection is a guess.
///
/// Both jumps and flights carry a confidence, and it is low for a reason worth
/// telling the rider: without motion data the call rests on the speed trace
/// alone. Hiding the weak ones would flatter the numbers, and quietly listing
/// them alongside the certain ones would be worse — so the uncertain ones are
/// shown, marked.
struct ConfidenceMark: View {

    let confidence: Double

    var body: some View {
        if confidence < 0.5 {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Low confidence detection")
                .help("Detected from the speed trace alone")
        }
    }
}
