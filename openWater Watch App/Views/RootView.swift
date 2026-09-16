import OpenWaterCore
import SwiftUI

/// Routes between the pre-session picker, the live session, and the moment
/// in between.
struct RootView: View {

    @Environment(SessionRecorder.self) private var recorder
    @Environment(WatchSettings.self) private var settings
    @Environment(WatchSyncClient.self) private var sync

    /// Set only when stopping could not put the session anywhere safe. A rider
    /// who pressed stop and was dropped back on the start screen has no way to
    /// tell "saved" from "gone", so silence is not an option here.
    @State private var saveFailure: SaveFailure?

    /// Stopping is not re-entrant: the dialog can be tapped twice on a wet
    /// screen, and the second pass would find the engine already finishing and
    /// report a failure for a session that saved perfectly well.
    @State private var isEnding = false

    var body: some View {
        Group {
            // Stopping gets its own screen. It used to leave the live pages
            // up — the controls page, with its Pause and Lock buttons, exactly
            // where the finger had just been — for however long the analysis
            // took, and then flip to the start screen while Health was still
            // closing the workout. Riders read that as "the end button did
            // nothing" and pressed it again.
            if recorder.isFinishing || recorder.state == .finishing {
                SavingView()
            } else {
                switch recorder.state {
                case .idle:
                    StartView()
                case .recording, .paused, .finishing:
                    LiveSessionView(onEnd: end)
                }
            }
        }
        .sheet(item: recoveryBinding) { candidate in
            RecoveryView(candidate: candidate)
        }
        .sheet(item: $saveFailure) { failure in
            SaveFailureView(failure: failure)
        }
    }

    private func end() {
        Task { await finish() }
    }

    /// Stop, and say so plainly if the session did not get anywhere safe.
    ///
    /// Every outcome ends in either a saved session or a sheet. This lives on
    /// the root rather than the live screen because the live screen is gone
    /// by the time the outcome is known.
    private func finish() async {
        guard !isEnding else { return }
        isEnding = true
        defer { isEnding = false }

        var saved = false
        let session = await recorder.finish { session in
            saved = sync.send(session)
            return saved
        }

        guard let session else {
            // Nothing was built. Either there were too few fixes to make a
            // session, or this is a second press — and a second press has
            // nothing to report.
            if recorder.state == .idle, !saved { saveFailure = .tooShort }
            return
        }
        if !saved { saveFailure = .notWritten(session) }
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

/// What the wrist shows between End and the start screen.
///
/// The work behind it is real: every fix of the session through every
/// detector, then the workout closed in Health with its route. A quiet
/// spinner with a word is enough; what it must not be is the screen the
/// rider just left.
struct SavingView: View {

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Saving session…")
                .font(.headline)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
