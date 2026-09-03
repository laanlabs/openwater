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

    @State private var failedToSave = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if failedToSave {
                    Text("Couldn't save that just now — the session is still on your watch. Try again.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

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
                    Task {
                        // Only dismissed once the session is genuinely
                        // somewhere. If the write fails the log is untouched
                        // and the prompt stays up, so the rider can try again
                        // rather than watch their one copy disappear into a
                        // tap.
                        if await recorder.recover(candidate, save: { sync.send($0) }) != nil {
                            dismiss()
                        } else {
                            failedToSave = true
                        }
                    }
                }
                .tint(.green)

                Button("Discard", role: .destructive) {
                    Task {
                        await recorder.dismissRecovery()
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
