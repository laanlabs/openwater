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

    let summary: SessionSummary
    let units: UnitPreferences

    private var jumps: [Jump] {
        summary.jumps.sorted { $0.airtime > $1.airtime }
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

    let session: Session
    let summary: SessionSummary
    let units: UnitPreferences
    var onEdit: () -> Void = {}

    private var flights: [Flight] {
        summary.flights.sorted { $0.duration > $1.duration }
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
