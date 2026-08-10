import OpenWaterCore
import SwiftUI

/// How the statistics across a whole library are arrived at.
///
/// A separate question from a single session's numbers, and one with its own
/// trap: the obvious way to average a season is to average the per-session
/// averages, which quietly gives a five-minute session the same weight as a
/// three-hour one. It does not do that, and this says so — along with which
/// clock it used, since the same moving-versus-overall choice applies again.
struct LibraryStatsNotesView: View {

    let sessions: [StoredSession]
    let period: SessionListView.Period

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var units: UnitPreferences { settings.units }

    private var totalMoving: TimeInterval {
        sessions.reduce(0) { $0 + $1.movingTime }
    }

    private var totalDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    private var totalDistance: Double {
        sessions.reduce(0) { $0 + $1.distance }
    }

    /// The same figure the card shows: distance covered while moving, over
    /// moving time.
    private var averageMoving: Double {
        let covered = sessions.reduce(0.0) {
            $0 + $1.distance * ($1.movingTime / max($1.duration, 1))
        }
        return totalMoving > 0 ? covered / totalMoving : 0
    }

    /// What the mean of the per-session averages would have given, shown so the
    /// difference between the two is visible rather than asserted.
    private var meanOfAverages: Double {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0) { $0 + $1.averageMovingSpeed } / Double(sessions.count)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These add up the \(sessions.count) session\(sessions.count == 1 ? "" : "s") currently shown — whatever the period and activity filters above are set to, not your whole library.")
                        .font(.callout)
                }

                Section {
                    row("Sessions", "\(sessions.count)")
                    row("Distance", Format.distance(totalDistance, unit: units.distance))
                    row("Total time", Format.duration(totalDuration))
                    row("Moving time", Format.duration(totalMoving))
                } header: {
                    Text("Totals")
                } footer: {
                    Text("Straight sums of each session's own figures. Every one of those was measured the way its own session explains — tap the ⓘ on a session card for that.")
                }

                Section {
                    row("Average moving", Format.speed(averageMoving, unit: units.speed, decimals: 1))
                    row("Mean of session averages", Format.speed(meanOfAverages, unit: units.speed, decimals: 1))
                } header: {
                    Text("Average speed")
                } footer: {
                    Text("""
                    The card shows the first: total distance covered while moving, divided by total moving time. It is the speed you actually held across everything shown.

                    The second is what averaging the per-session averages would give, and it is the wrong answer to almost any question you would ask — it lets a ten-minute session weigh as much as a three-hour one, so one short blast in a gale can lift a whole season. It is here only so the difference is visible rather than asserted.
                    """)
                }

                Section {
                    row("Fastest session", Format.speed(sessions.map(\.maxSpeed).max() ?? 0,
                                                        unit: units.speed, decimals: 1))
                } header: {
                    Text("Max speed")
                } footer: {
                    Text("The single best peak among the sessions shown, not an average of the peaks. It comes from one instant on one day and is only as good as that day's GPS — the session it came from will say how good that was.")
                }
            }
            .navigationTitle("How these are worked out")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("How the library stats are worked out")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}
