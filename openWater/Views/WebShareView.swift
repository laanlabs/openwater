import OpenWaterCore
import SwiftData
import SwiftUI

/// Publish a session to a public web page and hand back the link.
///
/// This is the only screen in openWater that sends anything off the device, and
/// it is written to make that unmissable rather than to make it frictionless.
/// The rider is told exactly what goes up and what stays, before the button —
/// not in a privacy policy they will never open. Everything else in the app
/// works offline and always will.
///
/// The link is the access control: anyone holding it can see the map, and there
/// is no way to take it back once it has been sent. That is stated plainly here
/// because a rider deciding whether to post it in a group chat needs to know it
/// now, not after.
struct WebShareView: View {

    let stored: StoredSession
    let session: Session

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var didCopy = false

    private enum Phase {
        case idle
        case uploading
        case shared(SharedLink)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                switch phase {
                case .idle, .uploading, .failed:
                    beforeSharing
                case .shared(let link):
                    result(link)
                }

                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Share a Link")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Share a Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: restoreExistingLink)
        }
    }

    // MARK: - Before

    @ViewBuilder
    private var beforeSharing: some View {
        Section {
            contents
        } header: {
            Text("What goes on the web")
        } footer: {
            Text("Anyone with the link can open it. Links can't be recalled once you've sent them.")
        }

        Section {
            Button {
                share()
            } label: {
                HStack {
                    if case .uploading = phase {
                        ProgressView()
                        Text("Uploading…")
                    } else {
                        Label("Create Link", systemImage: "link.badge.plus")
                    }
                }
            }
            .disabled(isUploading)
        }
    }

    private var contents: some View {
        Group {
            row(
                "map", "The track and your speeds",
                "Drawn on a map, coloured by speed, with your distance, duration and each speed category."
            )
            if settings.sharingPrivacy.maskEndpoints {
                row(
                    "lock.shield", "Start and finish trimmed",
                    "The first and last \(Int(settings.sharingPrivacy.endpointMaskRadius)) m are cut before upload, so the link doesn't show where you launched."
                )
            } else {
                row(
                    "exclamationmark.triangle", "Endpoint trimming is off",
                    "The link will show exactly where you started and finished. Turn trimming back on in Settings."
                )
            }
            row(
                "eye.slash", "Notes, gear and heart rate stay here",
                "So does your device, the raw GPS fixes and anything else the map doesn't need."
            )
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - After

    @ViewBuilder
    private func result(_ link: SharedLink) -> some View {
        Section {
            Text(link.url.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        } header: {
            Text("Your link")
        } footer: {
            Text(sharedFooter)
        }

        Section {
            ShareLink(item: link.url) {
                Label("Send Link", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = link.url.absoluteString
                withAnimation { didCopy = true }
            } label: {
                Label(didCopy ? "Copied" : "Copy Link", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            Link(destination: link.url) {
                Label("Open in Safari", systemImage: "safari")
            }
        }

        Section {
            Button("Create a New Link") { share() }
                .disabled(isUploading)
        } footer: {
            // Shares are write-once by design — nobody can swap the contents of
            // a link somebody else is holding — so a fresh upload is the only
            // way to publish changed data, and the old link keeps working.
            Text("Makes a second link with the session as it is now. The link above keeps working.")
        }
    }

    private var sharedFooter: String {
        guard let sharedAt = stored.sharedAt else { return "" }
        return "Shared \(sharedAt.formatted(date: .abbreviated, time: .shortened))."
    }

    // MARK: - Actions

    private var isUploading: Bool {
        if case .uploading = phase { return true }
        return false
    }

    /// Bring back the link from a previous share rather than making another one.
    private func restoreExistingLink() {
        guard case .idle = phase, let code = stored.shareCode else { return }
        phase = .shared(SharedLink(
            code: code,
            url: ShareDestination.openWater.linkURL(for: code),
            createdAt: stored.sharedAt ?? Date()
        ))
    }

    @MainActor
    private func share() {
        phase = .uploading
        didCopy = false

        // Building the snapshot walks the whole track, so it happens off the
        // main actor — a three-hour session would otherwise freeze the sheet
        // mid-tap.
        let session = self.session
        let privacy = settings.sharingPrivacy

        Task {
            do {
                let snapshot = await Task.detached {
                    ShareSnapshot.make(from: session, privacy: privacy)
                }.value
                let link = try await SharePublisher().publish(snapshot)
                stored.shareCode = link.code
                stored.sharedAt = link.createdAt
                withAnimation { phase = .shared(link) }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
