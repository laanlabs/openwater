import OpenWaterCore
import SwiftUI

/// Tell us about this screen.
///
/// Opened from wherever the rider already is, and it says so: the screen's
/// name travels with the note, because "the forecast is hard to read" and "the
/// model comparison is hard to read" are different tickets and nobody
/// remembers to say which one they meant.
///
/// Deliberately short. A feedback form that asks for a title, a category, a
/// severity and steps to reproduce gets filled in by nobody standing on a
/// beach. One choice, one box, and an email only if they want an answer.
struct AppFeedbackSheet: View {

    let screen: String

    @Environment(\.dismiss) private var dismiss

    @State private var kind: AppFeedback.Kind = .improvement
    @State private var text = ""
    @State private var contact = ""
    @State private var isSending = false
    @State private var failure: String?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What kind", selection: $kind) {
                        ForEach(AppFeedback.Kind.allCases) { kind in
                            Label(kind.label, systemImage: kind.icon).tag(kind)
                        }
                    }
                } header: {
                    Text("About \(screen)")
                } footer: {
                    Text("This goes to whoever builds the app, with the name of "
                         + "the screen you were on and nothing else about you.")
                }

                Section {
                    TextField(kind.prompt, text: $text, axis: .vertical)
                        .lineLimit(4...12)
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
            .navigationTitle("Send feedback")
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

    private func send() {
        isSending = true
        failure = nil
        let report = AppFeedback.Report(kind: kind, screen: screen, text: text, contact: contact)
        Task {
            do {
                try await AppFeedback.submit(report)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isSending = false
        }
    }
}

// MARK: - The button that opens it

/// A bug button in the navigation bar, on every screen in the app.
///
/// Two shapes, one control. On a session it opens the report that carries the
/// session's numbers, because a complaint about an analysis is worthless
/// without them. Everywhere else it opens the short form above, which carries
/// the screen's name instead. A rider should never have to work out which kind
/// of feedback they are giving — they tap the bug on whatever is in front of
/// them and say what they think.
struct FeedbackButton: ViewModifier {

    let screen: String
    /// Present only on a session screen.
    var session: Session?
    var summary: SessionSummary?

    @State private var isOpen = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isOpen = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Send feedback about \(screen)")
                }
            }
            .sheet(isPresented: $isOpen) {
                if let session, let summary {
                    FeedbackSheet(session: session, summary: summary)
                } else {
                    AppFeedbackSheet(screen: screen)
                }
            }
    }
}

extension View {
    /// A bug button on this screen, filing feedback about the app.
    func feedbackButton(_ screen: String) -> some View {
        modifier(FeedbackButton(screen: screen))
    }

    /// A bug button on this screen, filing a report against a session's own
    /// numbers.
    func feedbackButton(_ screen: String, session: Session, summary: SessionSummary) -> some View {
        modifier(FeedbackButton(screen: screen, session: session, summary: summary))
    }
}
