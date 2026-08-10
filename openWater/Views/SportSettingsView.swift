import OpenWaterCore
import SwiftUI

/// Every sport, and what openWater assumes about it.
///
/// The defaults are averages, and the things they average over — board, wing,
/// foil size, rider weight — vary more between two people on the same
/// discipline than between two disciplines. A heavier rider on a small front
/// wing does not take off where the wingfoil default says they do, so their
/// "time on foil" is a number about openWater's assumptions rather than about
/// their session.
///
/// A sport a rider has changed says so in the list, because a number that does
/// not match somebody else's is worth being able to find and explain.
struct SportSettingsView: View {

    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section {
                ForEach(Sport.recordable) { sport in
                    NavigationLink {
                        SportThresholdEditor(sport: sport)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sport.symbolName)
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            Text(sport.displayName)
                            Spacer(minLength: 0)
                            if settings.overrides(for: sport) != nil {
                                Text("Changed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("These set what counts as flying, what counts as moving, and how sharp a turn has to be before it is a turn. They apply to sessions as they are analysed — an existing session picks up a change when you edit it, trim it, or recompute from Your Data.")
            }
        }
        .navigationTitle("Sports")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Sports")
    }
}

/// The adjustable numbers for one sport.
struct SportThresholdEditor: View {

    let sport: Sport

    @Environment(AppSettings.self) private var settings

    private var defaults: SportThresholds { sport.thresholds }

    private var overrides: SportThresholds.Overrides {
        settings.sportOverrides[sport] ?? .init()
    }

    private func binding(
        _ key: WritableKeyPath<SportThresholds.Overrides, Double?>,
        default fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { overrides[keyPath: key] ?? fallback },
            set: { newValue in
                var o = overrides
                // Back at the default means back to *following* the default,
                // not pinned to today's value of it.
                o[keyPath: key] = abs(newValue - fallback) < 0.001 ? nil : newValue
                settings.sportOverrides[sport] = o.isEmpty ? nil : o
            }
        )
    }

    var body: some View {
        Form {
            if sport.isFoiling {
                Section {
                    speedRow(
                        "Flying above",
                        binding(\.foilTakeoffSpeed, default: defaults.foilTakeoffSpeed),
                        range: 2...12
                    )
                } header: {
                    Text("On foil")
                } footer: {
                    Text("The speed at which your foil is carrying you. It decides time on foil, flight count and the dry-gybe rate. Raise it if openWater thinks you are flying while you are still taxiing; lower it if long glides are being missed.")
                }
            }

            Section {
                speedRow(
                    "Moving above",
                    binding(\.movingSpeed, default: defaults.movingSpeed),
                    range: 0.2...5
                )
            } header: {
                Text("Moving")
            } footer: {
                Text("Below this you count as stopped. It sets moving time, the moving average, and how much of a session reads as \"Stopped\" — so on a light day it is the number that decides whether an hour of drifting drags your average down.")
            }

            if sport.isWindPowered {
                Section {
                    HStack {
                        Text("Turn is at least")
                        Spacer()
                        Text("\(Int(binding(\.maneuverHeadingChange, default: defaults.maneuverHeadingChange).wrappedValue))°")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: binding(\.maneuverHeadingChange, default: defaults.maneuverHeadingChange),
                        in: 40...150,
                        step: 5
                    )
                } header: {
                    Text("Turns")
                } footer: {
                    Text("How far you have to change heading before it counts as a gybe or a tack. Lower it and carving counts as turning; raise it and only committed transitions do.")
                }
            }

            if settings.overrides(for: sport) != nil {
                Section {
                    Button("Reset to defaults", role: .destructive) {
                        settings.sportOverrides[sport] = nil
                    }
                }
            }
        }
        .navigationTitle(sport.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Sport settings")
    }

    /// A speed, shown in the rider's own units and stored in m/s.
    private func speedRow(
        _ title: String,
        _ value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        let unit = settings.units.speed
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Format.speed(value.wrappedValue, unit: unit, decimals: 1))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.1)
            HStack {
                Text("Default \(Format.speed(defaultFor(title), unit: unit, decimals: 1))")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func defaultFor(_ title: String) -> Double {
        title == "Flying above" ? defaults.foilTakeoffSpeed : defaults.movingSpeed
    }
}
