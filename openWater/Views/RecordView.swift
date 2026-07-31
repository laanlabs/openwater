import CoreLocation
import OpenWaterCore
import SwiftUI

/// Recording on the phone.
///
/// The design constraint is different from the watch's: a phone on the water is
/// usually in a waterproof pouch on a harness, under an armband, or stuffed in a
/// wetsuit — glanced at occasionally at speed, not read. So the current speed is
/// enormous and everything else is secondary, and the controls are large enough
/// to hit with cold, wet hands through a plastic pouch.
struct RecordView: View {

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var sport: Sport = .wingfoil
    @State private var showingEndConfirmation = false
    @State private var savedSession: Session?

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.state {
                case .idle:
                    setup
                case .recording, .paused, .finishing:
                    live
                }
            }
            .navigationTitle(recorder.state == .idle ? "Record" : sport.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if recorder.state == .idle {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .onAppear {
                sport = settings.lastSport
                recorder.prepare()
                recorder.warmUpSensors()
                recorder.allTimeBests = library.records.mapValues(\.speed)
            }
            .confirmationDialog("End session?", isPresented: $showingEndConfirmation) {
                Button("End & Save") { end() }
                Button("Discard", role: .destructive) {
                    recorder.discard()
                    dismiss()
                }
                Button("Keep Recording", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(recorder.state != .idle)
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(spacing: 20) {
            Spacer()

            Picker("Sport", selection: $sport) {
                ForEach(orderedSports) { sport in
                    Label(sport.displayName, systemImage: sport.symbolName).tag(sport)
                }
            }
            .pickerStyle(.navigationLink)
            .padding(.horizontal)

            gpsStatus

            Spacer()

            Button {
                settings.lastSport = sport
                recorder.autoPauseEnabled = settings.autoPauseWhileRecording
                recorder.start(sport: sport)
            } label: {
                Label("Start", systemImage: "record.circle")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!canStart)
            .padding(.horizontal)

            if recorder.location.authorization == .denied {
                Text("openWater needs location access to record. Enable it in the Settings app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if !recorder.location.hasFix {
                // Starting before the receiver settles is the single most common
                // way to ruin a session's numbers, so it is called out rather
                // than discovered afterwards.
                Text("Waiting for a GPS fix. Starting now would leave the first minute of your track inaccurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer(minLength: 20)
        }
    }

    private var canStart: Bool {
        switch recorder.location.authorization {
        case .denied, .restricted: false
        default: true
        }
    }

    private var orderedSports: [Sport] {
        [.wingfoil, .parawing, .downwindSUP, .prone,
         .windfoil, .windsurf, .kitefoil, .kitesurf,
         .sail, .sup, .kayak, .efoil, .tow, .other]
    }

    private var gpsStatus: some View {
        let accuracy = recorder.location.latestAccuracy
        let good = accuracy >= 0 && accuracy <= 10
        return HStack(spacing: 6) {
            Image(systemName: recorder.location.hasFix ? "location.fill" : "location")
                .foregroundStyle(good ? .green : .orange)
            Text(
                recorder.location.hasFix
                    ? (accuracy >= 0 ? String(format: "GPS ±%.0f m", accuracy) : "GPS ready")
                    : "Finding satellites…"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Live

    private var live: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(Format.speed(
                recorder.metrics.currentSpeed,
                unit: settings.units.speed,
                decimals: 1,
                includeSymbol: false
            ))
            .font(.system(size: 110, weight: .semibold, design: .rounded))
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

            liveGrid
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

    private var liveGrid: some View {
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
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Button {
                showingEndConfirmation = true
            } label: {
                Label("End", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .font(.headline)
    }

    // MARK: - Actions

    private func end() {
        if let session = recorder.finish() {
            library.save(session)
        }
        dismiss()
    }
}
