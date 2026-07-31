import OpenWaterCore
import SwiftUI

/// Routes between the pre-session picker and the live session.
struct RootView: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings

    var body: some View {
        Group {
            switch recorder.state {
            case .idle:
                StartView()
            case .recording, .paused, .finishing:
                LiveSessionView()
            }
        }
        .sheet(item: recoveryBinding) { candidate in
            RecoveryView(candidate: candidate)
        }
    }

    /// The recovery prompt is presented as a sheet over whatever is showing, so
    /// an interrupted session is impossible to miss and impossible to lose by
    /// accident.
    private var recoveryBinding: Binding<RecordingEngine.RecoverableSession?> {
        Binding(
            get: { recorder.state == .idle ? recorder.recoverable : nil },
            set: { if $0 == nil { } }
        )
    }
}

/// Offered at launch when a previous session was cut short.
struct RecoveryView: View {

    let candidate: RecordingEngine.RecoverableSession

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSyncClient.self) private var sync
    @Environment(WatchSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Unfinished session", systemImage: "arrow.clockwise.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("openWater stopped before this session was saved. The track is still on your watch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Sport", value: candidate.sport.displayName)
                    LabeledContent("Started", value: candidate.startDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Duration", value: Format.duration(candidate.duration))
                    LabeledContent("Distance", value: Format.distance(candidate.distance, unit: settings.units.distance))
                }
                .font(.caption2)

                Button("Recover") {
                    if let session = recorder.recover(candidate) {
                        sync.send(session)
                    }
                    dismiss()
                }
                .tint(.green)

                Button("Discard", role: .destructive) {
                    recorder.dismissRecovery()
                    dismiss()
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
