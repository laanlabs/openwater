import SwiftUI

/// What the watch and the phone are doing for each other, said plainly.
///
/// The three states people actually hit are "no watch", "watch paired but the
/// app is not on it", and "working" — and the middle one is the one that used
/// to leave riders stuck, because iOS gives an app no way to install its own
/// watch companion. Nothing can do that but the rider, from the Watch app, so
/// the screen's job is to say so in the right words at the right moment rather
/// than to report three booleans and leave them to work it out.
struct WatchStatusView: View {

    @Environment(PhoneSyncClient.self) private var sync

    enum State: Equatable {
        case noWatch
        case notInstalled
        case installedNotReachable
        case connected

        var title: String {
            switch self {
            case .noWatch: "No Apple Watch paired"
            case .notInstalled: "Install openWater on your watch"
            case .installedNotReachable: "Watch app installed"
            case .connected: "Watch connected"
            }
        }

        var symbol: String {
            switch self {
            case .noWatch: "applewatch.slash"
            case .notInstalled: "applewatch.badge.exclamationmark"
            case .installedNotReachable: "applewatch"
            case .connected: "applewatch.radiowaves.left.and.right"
            }
        }

        var colour: Color {
            switch self {
            case .noWatch: .secondary
            case .notInstalled: .orange
            case .installedNotReachable: .blue
            case .connected: .green
            }
        }

        var detail: String {
            switch self {
            case .noWatch:
                "openWater records perfectly well on the iPhone alone. Pair an Apple Watch if you would rather leave the phone on the beach."
            case .notInstalled:
                "Your watch is paired but does not have openWater on it yet. Only you can install it — no app is allowed to do that for you."
            case .installedNotReachable:
                "Not connected this second, which is normal — the watch only talks to the phone when they are near each other. Sessions you record on the watch transfer as soon as it is back in range."
            case .connected:
                "Record on either one. Sessions recorded on the watch send themselves across as soon as the two are near each other — there is nothing to press. Your personal bests are kept in step too, so a live alert on the wrist means something real."
            }
        }
    }

    var state: State {
        if !sync.isPaired { return .noWatch }
        if !sync.isWatchAppInstalled { return .notInstalled }
        return sync.isReachable ? .connected : .installedNotReachable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(state.colour)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(state.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state == .notInstalled {
                installSteps
            }

            if state == .connected || state == .installedNotReachable {
                // The button for "my session is still on the watch".
                //
                // A transfer queued while the watch was out of range is retried
                // by the system on its own, but on its own can mean the next
                // time both devices happen to be awake together. A rider
                // standing in the car park wondering where their session went
                // needs to be able to ask now.
                Button {
                    sync.requestSync()
                } label: {
                    HStack(spacing: 6) {
                        if sync.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                        Text(sync.isSyncing ? "Checking the watch…" : "Check for sessions on the watch")
                    }
                    .font(.subheadline)
                }
                .disabled(sync.isSyncing)

                if let message = sync.lastSyncMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The one check a rider cannot make for themselves. Health
                // permissions live on the watch, the phone has no HealthKit
                // to ask with, and a declined prompt is invisible until a
                // session arrives with no beat in it.
                Button {
                    sync.checkHeartRate()
                } label: {
                    HStack(spacing: 6) {
                        if sync.isCheckingHeartRate {
                            ProgressView()
                        } else {
                            Image(systemName: "heart.text.square")
                        }
                        Text(sync.isCheckingHeartRate ? "Asking the watch…" : "Check heart rate")
                    }
                    .font(.subheadline)
                }
                .disabled(sync.isCheckingHeartRate)

                if let message = sync.heartRateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    sync.pushRecords()
                } label: {
                    Label("Send my bests to the watch", systemImage: "trophy")
                        .font(.subheadline)
                }
            }

            if let error = sync.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// The one-line summary under the title — the facts, for anybody who wants
    /// to check them rather than read a paragraph.
    private var statusLine: String {
        guard sync.isPaired else { return "This iPhone has no watch paired with it" }
        var parts = ["Paired"]
        parts.append(sync.isWatchAppInstalled ? "app installed" : "app not installed")
        if sync.isWatchAppInstalled { parts.append(sync.isReachable ? "in range" : "out of range") }
        if let last = sync.lastReceived {
            parts.append("last session \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    /// The actual steps, because "install it from the Watch app" is not enough
    /// detail for somebody who has never scrolled that list to the bottom.
    private var installSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Open the **Watch** app on this iPhone")
            step(2, "Tap **My Watch**, then scroll to **Available Apps**")
            step(3, "Find **openWater** and tap **Install**")

            Text("Already installed? Give it a moment — the watch reports in when it next connects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.tint, in: Circle())
            Text(.init(text))
                .font(.subheadline)
        }
    }
}

/// The same state as a single tappable pill, for the Record tab.
///
/// It shows up where the decision is actually made — about to start, phone in
/// one hand, deciding whether to take it with you — and it stays out of the way
/// once the watch is working: a rider with a connected watch does not need to
/// be told so before every session.
struct WatchPill: View {

    @Environment(PhoneSyncClient.self) private var sync
    @State private var showingDetail = false

    private var state: WatchStatusView.State {
        if !sync.isPaired { return .noWatch }
        if !sync.isWatchAppInstalled { return .notInstalled }
        return sync.isReachable ? .connected : .installedNotReachable
    }

    var body: some View {
        // Nothing at all when there is no watch to talk about, and nothing when
        // it is simply working.
        if sync.isPaired && state != .connected {
            Button {
                showingDetail = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.colour)
                    Text(state == .notInstalled
                         ? "Install openWater on your watch"
                         : "Watch out of range")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingDetail) {
                NavigationStack {
                    ScrollView {
                        WatchStatusView().padding()
                    }
                    .navigationTitle("Apple Watch")
                    .navigationBarTitleDisplayMode(.inline)
                    .feedbackButton("Apple Watch")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingDetail = false }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
