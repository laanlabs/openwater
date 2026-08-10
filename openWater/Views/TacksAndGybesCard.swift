import OpenWaterCore
import SwiftUI

/// Tacks and gybes, side by side, with the number that actually matters.
///
/// A turn count on its own says how busy the session was, not how well it
/// went. What a rider wants to know is how many they landed and how much
/// speed they kept — the two numbers you would compare against last week to
/// decide whether the new foil is working.
///
/// "Kept" is the slowest point of the turn, not the speed leaving it. A gybe
/// is won or lost at its slowest moment: exit speed recovers on its own if
/// you stayed up, so it flatters a bad turn that happened to be followed by a
/// gust.
struct TacksAndGybesCard: View {

    let summary: ManeuverSummary
    let maneuvers: [Maneuver]
    let units: UnitPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Tacks & Gybes")

            column(.gybe, count: summary.gybes, dry: summary.dryGybeRate)
            Divider()
            column(.tack, count: summary.tacks, dry: summary.dryTackRate)

            if summary.carves > 0 {
                Divider()
                row("Carves", "\(summary.carves)",
                    note: "Direction changes that never crossed the wind")
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func column(_ kind: Maneuver.Kind, count: Int, dry: Double?) -> some View {
        let name = kind == .gybe ? "Gybes" : "Tacks"
        let speeds = maneuvers.filter { $0.kind == kind }.map(\.minimumSpeed)

        VStack(alignment: .leading, spacing: 6) {
            row("Number of \(name)", "\(count)")

            // Missed rather than dry: a rider counts the ones they blew, and
            // the phrasing matches how they would say it out loud.
            row("% missed", dry.map { "\(Int(((1 - $0) * 100).rounded()))%" } ?? "—",
                note: dry == nil ? "Needs foil detection to know" : nil)

            if let best = speeds.max() {
                row("Best \(name.dropLast()) speed",
                    Format.speed(best, unit: units.speed, decimals: 1))
            }
            if !speeds.isEmpty {
                row("Avg \(name.dropLast()) speed",
                    Format.speed(speeds.reduce(0, +) / Double(speeds.count),
                                 unit: units.speed, decimals: 1))
            }
        }
    }

    private func row(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
