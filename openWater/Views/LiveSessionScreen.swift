import OpenWaterCore
import SwiftUI

/// The screen while a session is recording.
///
/// A phone on the water is in a pouch on a harness, under an armband, or in a
/// wetsuit — glanced at, not read. So the current speed is enormous and
/// everything else is secondary, and the controls are large enough to hit with
/// cold, wet hands through a sheet of plastic.
struct LiveSessionScreen: View {

    @Binding var showingEndConfirmation: Bool

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(Format.speed(
                recorder.metrics.currentSpeed,
                unit: settings.units.speed,
                decimals: 1,
                includeSymbol: false
            ))
            .font(.system(size: 108, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .foregroundStyle(recorder.state == .paused ? .secondary : .primary)
            .contentTransition(.numericText())

            Text(settings.units.speed.symbol)
                .font(.headline)
                .foregroundStyle(.secondary)

            if recorder.state == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }

            Spacer()

            grid
                .padding(.horizontal)

            if let record = recorder.recordsHit.first {
                Label(
                    "New best \(record.category.shortName): \(Format.speed(record.speed, unit: settings.units.speed))",
                    systemImage: "trophy.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.yellow)
                .padding(.top, 12)
            }

            Spacer()

            controls
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
            SummaryTile(label: "Max", value: Format.speed(
                recorder.metrics.maxSpeed, unit: settings.units.speed, decimals: 1, includeSymbol: false
            ))
            SummaryTile(label: "10 s", value: Format.speed(
                recorder.metrics.current10s, unit: settings.units.speed, decimals: 1, includeSymbol: false
            ))
            SummaryTile(label: "Distance", value: Format.distance(
                recorder.metrics.distance, unit: settings.units.distance
            ))
            SummaryTile(label: "Time", value: Format.duration(recorder.metrics.duration))
            SummaryTile(label: "Runs", value: "\(recorder.metrics.runCount)")
            if recorder.sport.isFoiling {
                SummaryTile(label: "On foil", value: Format.duration(recorder.metrics.timeOnFoil))
            }
            SummaryTile(label: "Best 500 m", value: {
                let best = recorder.metrics.best(.distance(metres: 500))
                return best > 0
                    ? Format.speed(best, unit: settings.units.speed, decimals: 1, includeSymbol: false)
                    : "—"
            }())
            SummaryTile(label: "GPS", value: recorder.metrics.horizontalAccuracy >= 0
                ? String(format: "±%.0f m", recorder.metrics.horizontalAccuracy)
                : "—")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.state == .paused {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Button {
                showingEndConfirmation = true
            } label: {
                Label("End", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .font(.headline)
    }
}
