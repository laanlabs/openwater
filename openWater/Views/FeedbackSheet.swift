#if DEBUG
import OpenWaterCore
import SwiftUI

/// Say what this session's analysis got wrong, from the session itself.
///
/// Deliberately opened from the session being judged rather than from a
/// general feedback screen, so the note carries the numbers it is about
/// without anybody having to transcribe them. The panel showing those numbers
/// is not decoration — it is what the note will be filed against, shown so
/// there is no doubt what is being disputed.
struct FeedbackSheet: View {

    let session: Session
    let summary: SessionSummary

    @Environment(\.dismiss) private var dismiss

    @State private var verdict: SessionFeedback.Verdict = .wrong
    @State private var text = ""
    @State private var isSending = false
    @State private var failure: String?
    @State private var sent = false

    private var note: SessionFeedback.Note {
        SessionFeedback.note(for: session, summary: summary,
                            verdict: verdict, text: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Verdict", selection: $verdict) {
                        ForEach(SessionFeedback.Verdict.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(verdict.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("What's wrong with it") {
                    TextField(
                        "How many runs would you say this was? What did the analysis miss?",
                        text: $text, axis: .vertical
                    )
                    .lineLimit(4...12)
                }

                Section {
                    LabeledContent("Session", value: note.session)
                    LabeledContent("Runs", value:
                        "\(note.runsDownwind) downwind · \(note.runsReaching) reaching · \(note.runsUpwind) upwind")
                    LabeledContent("Stretches", value: "\(note.stretches)")
                    LabeledContent("Flights", value: "\(note.flights)")
                    LabeledContent("Analysis", value: "v\(note.analysisVersion)")
                } header: {
                    Text("Filed against")
                } footer: {
                    Text("Saved with the note, so it still means something after the numbers move.")
                }

                if let failure {
                    Section {
                        Text(failure)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(sent ? "Sent" : "Session feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending…" : "Send") { send() }
                        .fontWeight(.semibold)
                        .disabled(isSending ||
                                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func send() {
        isSending = true
        failure = nil
        let note = note
        Task {
            do {
                try await SessionFeedback.submit(note)
                sent = true
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isSending = false
        }
    }
}
#endif
