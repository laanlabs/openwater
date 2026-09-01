import OpenWaterCore
import SwiftUI

/// What counts as a wave ride, in the rider's own hands.
///
/// The defaults are a guess about water the rider was in and we were not. A
/// wing rider in short chop reported a thirty-second ride ending five seconds
/// early — still eleven knots, still twenty degrees off the swell, still on
/// the foil, and cut because the deck was rattling hard enough to fail the
/// accelerometer's quiet test. That is not an argument for a different
/// constant; it is an argument for the rider being able to say what a wave is
/// on their board, in their water, the way they already can for a glide.
///
/// So this sits behind the gear on the Wave Rides screen, next to the rides it
/// produced, and shows what the change does before it is committed to: the
/// count, the longest and the riding time all follow the sliders. Every rule
/// starts where it has always been, and one left alone keeps following the
/// glide rule it borrowed — see `SportThresholds`.
struct WaveRulesSheet: View {

    let session: Session
    let summary: SessionSummary
    let swellFrom: Double

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// What the sliders currently produce. Recomputed off the rules rather
    /// than in `body`, so a drag is not re-analysing the track on every frame
    /// of the animation as well as every change.
    @State private var preview: WaveRideSummary?

    private var sport: Sport { session.sport }
    private var units: UnitPreferences { settings.units }

    private var thresholds: SportThresholds { settings.thresholds(for: sport) }
    private var finder: WaveRideFinder { WaveRideFinder(thresholds: thresholds) }

    private var overrides: SportThresholds.Overrides {
        settings.sportOverrides[sport] ?? .init()
    }

    /// Is anything here the rider's own rather than inherited?
    private var isTuned: Bool {
        let o = overrides
        return o.waveConeAngle != nil || o.waveSpeedFraction != nil
            || o.waveMinimumGain != nil || o.waveMinimumDuration != nil
            || o.waveBridgeSeconds != nil || o.waveQuietFraction != nil
    }

    // MARK: - The rules

    /// A slider's value: the rider's own where they have set one, the
    /// inherited answer where they have not — and back at the inherited value
    /// it goes back to *following* that rule rather than pinning today's
    /// number.
    private func rule(
        _ key: WritableKeyPath<SportThresholds.Overrides, Double?>,
        inherited: Double,
        tolerance: Double = 0.001
    ) -> Binding<Double> {
        Binding(
            get: { overrides[keyPath: key] ?? inherited },
            set: { value in
                var o = overrides
                o[keyPath: key] = abs(value - inherited) < tolerance ? nil : value
                settings.sportOverrides[sport] = o.isEmpty ? nil : o
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                resultSection
                coneSection
                paceSection
                chopSection
                lengthSection
                resetSection
            }
            .navigationTitle("What counts as a ride")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Session · Wave rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: thresholds) { recount() }
        }
    }

    /// The whole point of tuning in front of the rides: the answer moves
    /// while the slider is under the thumb.
    private var resultSection: some View {
        Section {
            HStack(spacing: 18) {
                measure(preview.map { "\($0.count)" } ?? "—", "waves")
                measure(Format.shortDuration(preview?.longest?.duration ?? 0), "longest")
                measure(Format.shortDuration(preview?.timeOnWaves ?? 0), "riding")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        } footer: {
            Text("This session, under the rules below. They apply to every \(sport.displayName.lowercased()) session — the rides are found when a screen asks for them, so nothing has to be re-analysed.")
        }
    }

    private func measure(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Direction

    private var coneSection: some View {
        Section {
            slider(
                "How far off the wave",
                rule(\.waveConeAngle, inherited: WaveRideFinder.halfAngle, tolerance: 0.5),
                range: 30...90, step: 5,
                reading: "\(Int(finder.coneAngle))°"
            )
            slider(
                "Carve tolerance",
                rule(\.waveBridgeSeconds, inherited: WaveRideFinder.bridgeSeconds, tolerance: 0.4),
                range: 0...20, step: 1,
                reading: "\(Int(finder.bridgeSeconds)) s"
            )
        } header: {
            Text("Which way you were going")
        } footer: {
            Text("Straight down the face is 0°; down the line — along the face, outrunning the wave — sits 40 to 60 off. Past the cone the board is running along the trough or over the back, and the wave is no longer what is carrying you. The carve tolerance is how long a turn up the face may point out of that cone before the ride is called finished.")
        }
    }

    // MARK: Pace

    private var paceSection: some View {
        Section {
            slider(
                "Pace to hold",
                rule(\.waveSpeedFraction, inherited: thresholds.glideSpeedFraction),
                range: 0.4...1.0, step: 0.05,
                reading: "\(Int((finder.speedFraction * 100).rounded()))%"
            )
            slider(
                "The wave has to add",
                rule(\.waveMinimumGain,
                     inherited: max(thresholds.glideMinimumGain, WaveRideFinder.minimumGain)),
                range: 0...0.4, step: 0.02,
                reading: "\(Int((finder.minimumRise * 100).rounded()))%"
            )
        } header: {
            Text("What the water gave you")
        } footer: {
            Text("Pace is measured against your own median speed with the swell that day, not an absolute number, so it means the same thing in six knots and in twenty. The second is the rise: a wave gives speed for nothing, and without a gain over the lull before it a stretch is a reach that happens to point at the beach. Lower it if rides are being missed on a small day.")
        }
    }

    // MARK: Chop

    private var chopSection: some View {
        Section {
            slider(
                "Board may rattle",
                rule(\.waveQuietFraction, inherited: thresholds.pumpEnergyFraction, tolerance: 0.05),
                range: 1...SportThresholds.waveChopIgnored, step: 0.25,
                reading: finder.consultsMotion
                    ? String(format: "%.2f×", finder.quietFraction)
                    : "ignored"
            )
        } header: {
            Text("How quiet the board must be")
        } footer: {
            Text(finder.consultsMotion
                 ? "A ride ends when the accelerometer says the board is being worked rather than carried, measured against this session's own median so it means the same on a watch and in a vest. In short chop the deck is never quiet, and this is the rule most likely to be cutting a ride short while you are still on the wave — drag it right until the ride runs to where you remember it ending. All the way right stops the accelerometer being consulted at all."
                 : "The accelerometer is not consulted: speed, direction and the rise decide a ride on their own. This is the honest setting for a wing in short chop, where the board rattles the whole way down the line. Drag it back left to have the rattle end a ride again.")
        }
    }

    // MARK: Length

    private var lengthSection: some View {
        Section {
            slider(
                "Shortest ride",
                rule(\.waveMinimumDuration, inherited: thresholds.glideMinimumDuration, tolerance: 0.4),
                range: 3...30, step: 1,
                reading: "\(Int(finder.shortestRide)) s"
            )
        } footer: {
            Text("Anything shorter is still counted in the riding time — it is simply not given a number of its own on the map and in the list.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Back to the defaults", role: .destructive) {
                var o = overrides
                o.waveConeAngle = nil
                o.waveSpeedFraction = nil
                o.waveMinimumGain = nil
                o.waveMinimumDuration = nil
                o.waveBridgeSeconds = nil
                o.waveQuietFraction = nil
                settings.sportOverrides[sport] = o.isEmpty ? nil : o
            }
            .disabled(!isTuned)
        } footer: {
            Text(isTuned
                 ? "Only the wave rules go back; anything you have changed about flying, turns or glides stays as it is."
                 : "Nothing here has been changed from the defaults.")
        }
    }

    // MARK: - Chrome

    private func slider(
        _ title: String,
        _ value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        reading: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(reading)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                // The row's title is drawn as its own Text, which leaves the
                // slider itself unnamed to VoiceOver — and to anything else
                // reading the screen.
                .accessibilityLabel(title)
                .accessibilityValue(reading)
        }
    }

    /// Re-find the rides under the current rules.
    ///
    /// Off the main actor: it is a handful of linear passes over the track,
    /// which is nothing on a twenty-minute session and is not nothing on a
    /// three-hour one with a thumb on a slider.
    private func recount() {
        let track = session.track
        let flights = summary.flights
        let rules = thresholds
        let swell = swellFrom
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                WaveRideFinder(thresholds: rules)
                    .rides(in: track, flights: flights, swellFrom: swell)
            }.value
            withAnimation(.snappy) { preview = found }
        }
    }
}
