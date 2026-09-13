import OpenWaterCore
import OpenWaterSpots
import SwiftUI

// MARK: - The source, for a phone

/// The camera's own page as a code, whatever this box is showing of it.
///
/// A camera that plays here is still worth opening on a phone: the stream the
/// TV found may be one angle of several, a YouTube manifest behind a switch
/// in Settings, or a playlist read off the page a minute ago — and the page
/// itself is what the operator actually publishes. So this is offered on
/// every camera, not only the ones that fell through to a code.
struct CamSourceCode: View {

    let cam: SpotGuideStore.GuideResource

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 22) {
                Text(cam.displayName)
                    .font(.system(size: 54, weight: .bold))
                    .lineLimit(3)
                Label(cam.providerLabel, systemImage: "globe")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("This is the camera's own page. Scan it to watch on your phone, or to see everything the operator publishes with it.")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Button("Done") { dismiss() }
                    .padding(.top, 16)
            }
            .frame(maxWidth: 760, alignment: .leading)

            VStack(spacing: 18) {
                QRCodeCard(link: cam.url)
                Text("Point your phone's camera at the code")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(cam.url.absoluteString)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 440)
            }
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Painted, not inherited — see `CamHandoff`. A Light Apple TV
        // otherwise draws this black on black.
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}

// MARK: - Reporting one

/// "This camera is broken", from a sofa, in two presses.
///
/// Reasons first, words optional. Typing on a television is a chore — an
/// on-screen keyboard or a phone nudged into service — so the common problems
/// are one press each, and the note is there for the rider who has more to
/// say. Either way the ticket carries what the rider should not have to
/// transcribe: which camera, its page, and what this box was actually showing.
///
/// Files through `AppFeedback`, the same contract the phone's camera report
/// uses, so a report from a TV and one from a phone land side by side.
struct CamReportScreen: View {

    let cam: SpotGuideStore.GuideResource
    let route: CamRoute

    @Environment(\.dismiss) private var dismiss

    @State private var reason: Reason?
    @State private var note = ""
    @State private var state: SendState = .composing
    @FocusState private var isOnDone: Bool

    private enum SendState: Equatable {
        case composing, sending, sent
        case failed(String)
    }

    enum Reason: String, CaseIterable, Identifiable {
        case wontPlay, frozen, wrongPlace, wrongName, playsElsewhere, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wontPlay: "It won't play"
            case .frozen: "The picture is frozen or out of date"
            case .wrongPlace: "It isn't where it says it is"
            case .wrongName: "The name is wrong"
            case .playsElsewhere: "It plays on the web, but not here"
            case .other: "Something else"
            }
        }

        var icon: String {
            switch self {
            case .wontPlay: "video.slash"
            case .frozen: "clock.badge.exclamationmark"
            case .wrongPlace: "mappin.slash"
            case .wrongName: "character.cursor.ibeam"
            case .playsElsewhere: "globe"
            case .other: "ellipsis.bubble"
            }
        }

        /// Which of the rule's four types this files as. A wrong name or a
        /// stream the TV could be reading are improvements to the guide; the
        /// rest are a camera that is broken as it stands.
        var kind: AppFeedback.Kind {
            switch self {
            case .wontPlay, .frozen, .wrongPlace: .bug
            case .wrongName, .playsElsewhere: .improvement
            case .other: .other
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Report a camera")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(cam.displayName)
                    .font(.system(size: 50, weight: .bold))
                    .lineLimit(2)
                Label(cam.providerLabel, systemImage: "globe")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("Your report goes with the camera's page, what this Apple TV was showing, and the app version, so the camera can be fixed or taken off the list.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .frame(maxWidth: 620, alignment: .leading)

            Group {
                if state == .sent { sent } else { form }
            }
            .frame(maxWidth: 820, alignment: .leading)
        }
        .padding(.horizontal, 90)
        .padding(.vertical, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Reason.allCases) { option in
                    Button { reason = option } label: {
                        HStack(spacing: 18) {
                            Image(systemName: reason == option ? "checkmark.circle.fill" : option.icon)
                                .frame(width: 40)
                            Text(option.label)
                            Spacer()
                        }
                        .font(.system(size: 26))
                    }
                }

                TextField("Anything to add? (optional)", text: $note)
                    .padding(.top, 10)

                HStack(spacing: 24) {
                    Button(state == .sending ? "Sending…" : "Send report", action: send)
                        .disabled(reason == nil || state == .sending)
                    if case .failed(let why) = state {
                        Label(why, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if reason == nil {
                        Text("Pick what's wrong first")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 10)
            }
            .padding(.vertical, 20)
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Sent — thank you", systemImage: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .bold))
            Text("It's filed against this camera with its page attached.")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .focused($isOnDone)
                .padding(.top, 10)
        }
        .padding(.top, 20)
        .onAppear { isOnDone = true }
    }

    private func send() {
        guard let reason else { return }
        state = .sending
        let words = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = AppFeedback.Report(
            kind: reason.kind,
            screen: "Camera — \(cam.displayName)",
            text: words.isEmpty ? reason.label : "\(reason.label)\n\n\(words)",
            context: context
        )
        Task {
            do {
                try await AppFeedback.submit(report)
                state = .sent
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Leads with the same two lines the phone's report does, so a sweep reads
    /// both the same way; the rest is what only the TV knows.
    private var context: String {
        var lines = [
            "Camera: \(cam.displayName)",
            "Source: \(cam.url.absoluteString)",
        ]
        if let provider = cam.provider { lines.append("Provider: \(provider)") }
        lines.append(String(format: "Location: %.5f, %.5f",
                            cam.coordinate.latitude, cam.coordinate.longitude))
        lines.append("Showing: \(route.summary)")
        lines.append("Seen on: Apple TV")
        return lines.joined(separator: "\n")
    }
}
