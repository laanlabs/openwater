import OpenWaterCore
import SwiftUI

/// Tell us what this session got wrong.
///
/// Opened from the session being judged, not from a general feedback screen,
/// so the numbers being disputed travel with the complaint and nobody has to
/// transcribe them. The "what it currently says" panel is not decoration — it
/// is what the report is filed against, shown so there is no doubt about
/// which claim is being called wrong.
///
/// The recording toggle is off every time it opens and says exactly what it
/// sends. A GPS track is the most sensitive thing this app holds, and the
/// only honest way to ask for one is in the words a rider would use to
/// describe what they are handing over.
struct FeedbackSheet: View {

    let session: Session
    let summary: SessionSummary

    @Environment(\.dismiss) private var dismiss

    @State private var topic: SessionFeedback.Topic = .runs
    @State private var text = ""
    @State private var contact = ""
    @State private var sendsRecording = false
    @State private var isSending = false
    @State private var failure: String?

    private var report: SessionFeedback.Report {
        SessionFeedback.report(for: session, summary: summary, topic: topic, text: text)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What's wrong", selection: $topic) {
                        ForEach(SessionFeedback.Topic.allCases) { topic in
                            Label(topic.rawValue, systemImage: topic.icon).tag(topic)
                        }
                    }
                } footer: {
                    Text("The analysis is tuned against sessions people tell us about. "
                         + "Being specific about what it should have said is the most useful thing you can send.")
                }

                Section {
                    TextField(topic.prompt, text: $text, axis: .vertical)
                        .lineLimit(4...12)
                }

                Section {
                    currentNumbers
                } header: {
                    Text("What it currently says")
                } footer: {
                    Text("Sent with your note so it still makes sense after these numbers change.")
                }

                Section {
                    Toggle("Send my recording too", isOn: $sendsRecording)
                } footer: {
                    Text(sendsRecording
                         ? "This attaches the full GPS track of this session — everywhere you went, "
                           + "and when. It lets us reproduce exactly what you are seeing. It is never "
                           + "published, and it is only ever sent when you turn this on."
                         : "Off. Only your note and the numbers above are sent — no location data. "
                           + "Turn this on if you want us to be able to reproduce the problem.")
                }

                Section {
                    TextField("Email (optional)", text: $contact)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Only if you would like a reply. Leave it blank to stay anonymous.")
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending…" : "Send") { send() }
                        .fontWeight(.semibold)
                        .disabled(!canSend)
                }
            }
        }
    }

    @ViewBuilder
    private var currentNumbers: some View {
        let report = report
        LabeledContent("Runs",
                       value: "\(report.runsDownwind) downwind · \(report.runsReaching) reaching · \(report.runsUpwind) upwind")
        LabeledContent("On foil",
                       value: "\(Int((report.foilingFraction * 100).rounded()))% · \(report.flights) flights")
        LabeledContent("Turns, falls, jumps",
                       value: "\(report.turns) · \(report.falls) · \(report.jumps)")
        if let direction = report.windDirection {
            LabeledContent("Wind", value: "\(Format.cardinal(direction)) \(Int(direction.rounded()))°")
        }
    }

    private func send() {
        isSending = true
        failure = nil

        var outgoing = report
        outgoing.contact = contact
        // Encoded here, at the moment of consent — a sheet that is opened,
        // read and cancelled never turns a track into bytes.
        if sendsRecording {
            outgoing.recording = SessionFeedback.recording(of: session)
        }

        Task {
            do {
                try await SessionFeedback.submit(outgoing)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isSending = false
        }
    }
}
