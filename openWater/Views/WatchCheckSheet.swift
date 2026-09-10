import SwiftUI

/// "Is my session still on the watch?", answered by asking rather than by
/// explaining where the answer lives.
///
/// The rider this is for is standing in a car park with a watch on their wrist
/// and a session they cannot find. Everything needed to help them already
/// existed — Settings ▸ Apple Watch has the same two buttons — and that is
/// exactly the problem: it is three taps away, behind a word ("Settings") that
/// nobody reads as "get my session off my watch". So the check comes to the
/// front of the app, one tap from the library the session is missing from.
///
/// **It runs itself.** Opening this sheet asks the watch immediately rather
/// than presenting two buttons to press. A screen that asks somebody to press
/// "Check" has made them responsible for the checking; this one has already
/// started by the time they have read the title, which is the difference
/// between a diagnostic panel and an answer.
///
/// **And it keeps running.** The watch replies with a count in a fraction of a
/// second, and then the sessions themselves arrive one file at a time over the
/// following seconds. The old message said "sending 3 sessions…" and stopped
/// there, so three sessions still in flight looked exactly like three sessions
/// lost. The progress row counts them in.
struct WatchCheckSheet: View {

    @Environment(PhoneSyncClient.self) private var sync
    @Environment(\.dismiss) private var dismiss

    /// How many sessions the library had when the asking began, so arrivals
    /// can be counted without the client having to keep a per-screen tally.
    @State private var baseline = 0
    /// Whether a run has been started for this presentation.
    @State private var hasRun = false
    /// Held true for a moment after the replies land — see `runChecks`.
    @State private var isDwelling = false

    /// How tall the sheet is sitting.
    ///
    /// Owned here rather than at the call site, because only this screen knows
    /// what it is about to draw. Medium is right for the answer everybody gets
    /// — three lines and a tick — and wrong the moment a walk-through appears
    /// under it: measured on the simulator, step 3 of the Health route was
    /// below the fold, which on a screen whose whole job is to walk somebody
    /// through something is the one place it must not be.
    @State private var detent: PresentationDetent = .medium

    /// Whether what is on screen has steps that need the room.
    private var needsRoom: Bool {
        switch state {
        case .notInstalled: true
        case .connected: sync.heartRate?.hasSteps == true
        default: false
        }
    }

    /// The least time the spinners stay up.
    ///
    /// A reachable watch answers both questions in well under a tenth of a
    /// second, and a spinner that appears and vanishes inside one frame reads
    /// as nothing having happened at all — which sends the rider straight back
    /// to pressing the button again. The work is real; this only makes it
    /// visible. It is a floor on the display, never on the asking.
    private static let dwell = Duration.milliseconds(1100)

    private var state: WatchStatusView.State {
        if !sync.isPaired { return .noWatch }
        if !sync.isWatchAppInstalled { return .notInstalled }
        return sync.isReachable ? .connected : .installedNotReachable
    }

    /// How many sessions have landed since the asking began.
    private var arrived: Int { max(0, sync.receivedCount - baseline) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch state {
                    case .noWatch:
                        Text(WatchStatusView.State.noWatch.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .notInstalled:
                        Text(WatchStatusView.State.notInstalled.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        WatchInstallSteps()

                    case .installedNotReachable:
                        outOfRange

                    case .connected:
                        sessionsRow
                        Divider()
                        heartRateRow
                    }

                    if let error = sync.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Watch check")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        // Grows, never shrinks. A sheet that dropped back to medium when the
        // rider had dragged it up would be taking the screen off them.
        .onChange(of: needsRoom, initial: true) { _, needs in
            if needs { detent = .large }
        }
        // Runs on arrival, and again if the watch comes into range while the
        // sheet is open — which is the ordinary case of a rider opening this,
        // seeing "out of range", and lifting their wrist.
        .task(id: sync.isReachable) {
            guard sync.isReachable else { return }
            await runChecks()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbol)
                .font(.system(size: 34))
                .foregroundStyle(state.colour)
                .frame(width: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

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

    // MARK: - Out of range

    /// The state that looks like a fault and is not one.
    ///
    /// Nothing here can force a connection: the two devices talk when they are
    /// near each other and one of them is awake. So this says the one thing
    /// that actually works — wake the watch — and promises the rest, because
    /// a queued transfer really does arrive on its own.
    private var outOfRange: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your watch is not answering this second. It only talks to the phone when the two are near each other and one of them is awake.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WatchStep(1, "Bring the watch near this iPhone")
            WatchStep(2, "Raise your wrist, or open **openWater** on the watch")

            Text("Anything it is holding sends itself across as soon as it is back in range — this screen picks up the moment it answers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Listening for your watch…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - The two checks

    private var isCheckingSessions: Bool { sync.isSyncing || isDwelling }

    private var sessionsRow: some View {
        CheckRow(title: "Sessions on the watch",
                 isBusy: isCheckingSessions,
                 symbol: sessionsSymbol,
                 tint: sessionsTint) {
            Text(sessionsDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A second spinner, and it earns its place: the first one is
            // "asking", this one is "carrying". They are different waits and
            // only the second has a number attached.
            if let queued = sync.queuedOnWatch, queued > 0, arrived < queued, !isCheckingSessions {
                ProgressView(value: Double(arrived), total: Double(queued))
                    .progressViewStyle(.linear)
                    .padding(.top, 2)
            }
        }
    }

    private var sessionsSymbol: String {
        guard let queued = sync.queuedOnWatch else { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if queued == 0 { return "checkmark.circle.fill" }
        return arrived >= queued ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    private var sessionsTint: Color {
        guard let queued = sync.queuedOnWatch else { return .secondary }
        return queued == 0 || arrived >= queued ? .green : .blue
    }

    private var sessionsDetail: String {
        if isCheckingSessions { return "Asking your watch what it is holding…" }
        guard let queued = sync.queuedOnWatch else {
            // No count means the ask itself failed, and the client's message
            // is the error rather than a summary.
            return sync.lastSyncMessage ?? "Could not ask your watch."
        }
        if queued == 0 { return "Your watch has nothing waiting. Everything it recorded is already here." }
        let sessions = queued == 1 ? "session" : "sessions"
        if arrived >= queued {
            return "\(queued) \(sessions) came across. They are in your library now."
        }
        return "\(queued) \(sessions) on the way — \(arrived) of \(queued) arrived. They land one at a time; you can leave this screen."
    }

    private var isCheckingHeart: Bool { sync.isCheckingHeartRate || isDwelling }

    private var heartRateRow: some View {
        CheckRow(title: "Heart rate",
                 isBusy: isCheckingHeart,
                 symbol: heartSymbol,
                 tint: heartTint) {
            Text(heartLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Steps only for the one answer that has somewhere to go. The
            // route is written out rather than linked because there is no URL
            // that opens the Health app at this pane — and a rider told
            // "permission is off" without being told where the switch is
            // looks for it in this app's settings, which is the one place it
            // is not.
            if !isCheckingHeart, sync.heartRate == .off {
                VStack(alignment: .leading, spacing: 8) {
                    WatchStep(1, "Open the **Health** app on this iPhone")
                    WatchStep(2, "Tap your picture, top right, then **Privacy** ▸ **Apps**")
                    WatchStep(3, "Choose **openWater** and turn on **Heart Rate**")

                    Text("It applies to the next session — the ones already recorded cannot get a heartbeat back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            if !isCheckingHeart, sync.heartRate == .notAsked {
                Text("The Health prompt only appears at the start of a session, so there is no switch to go and find yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            liveReading
        }
    }

    /// The check above proves openWater may read heart rate. This one proves
    /// the watch will collect it — which is the question, and not the same
    /// question, because a workout session that will not start passes the
    /// first and fails the second.
    ///
    /// Asked for rather than automatic: it holds a workout session open on the
    /// wrist for up to fifteen seconds, which is not something to do to a
    /// rider's battery every time a sheet opens.
    @ViewBuilder
    private var liveReading: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = sync.liveHeartRate, !sync.isTakingReading {
                Label {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: result.symbol)
                        .foregroundStyle(result.isGood ? .green : .orange)
                }
            }

            Button {
                sync.takeHeartRateReading()
            } label: {
                HStack(spacing: 6) {
                    if sync.isTakingReading {
                        ProgressView()
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                    Text(sync.isTakingReading
                         ? "Reading — keep the watch on…"
                         : (sync.liveHeartRate == nil ? "Take a live reading" : "Read again"))
                }
                .font(.subheadline)
            }
            .disabled(sync.isTakingReading)

            if sync.liveHeartRate == nil, !sync.isTakingReading {
                Text("Collects one real beat on the watch, the same way a session does. Takes up to fifteen seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The finding, with the route left to the steps when there are steps.
    private var heartLine: String {
        if isCheckingHeart { return "Asking the watch whether it can read your heartbeat…" }
        guard let state = sync.heartRate else {
            // No state means the ask itself failed, and the client's message
            // is the error rather than a verdict.
            return sync.heartRateMessage ?? "Not checked."
        }
        return state.headline
    }

    private var heartSymbol: String {
        switch sync.heartRate {
        case .on: "checkmark.circle.fill"
        case .off, .notAsked: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle"
        case nil: "heart.text.square"
        }
    }

    private var heartTint: Color {
        switch sync.heartRate {
        case .on: .green
        case .off: .orange
        case .notAsked: .blue
        case .unavailable, nil: .secondary
        }
    }

    // MARK: - Running them

    /// Ask both questions at once, and keep the answer on screen long enough
    /// to have been seen.
    ///
    /// Both are `sendMessage` round trips with their own reply handlers, so
    /// firing them together costs one wait rather than two and neither can
    /// block the other. The dwell is the only artificial part, and it is a
    /// floor on the spinner rather than a delay on the work — the replies land
    /// when they land, and the row redraws with them.
    private func runChecks() async {
        guard !hasRun else { return }
        hasRun = true
        baseline = sync.receivedCount
        isDwelling = true
        sync.requestSync()
        sync.checkHeartRate()
        try? await Task.sleep(for: Self.dwell)
        isDwelling = false
    }
}

// MARK: - Pieces

/// One thing being checked: a glyph that turns into a verdict, a title, and
/// whatever the check has to say underneath.
private struct CheckRow<Detail: View>: View {

    let title: String
    let isBusy: Bool
    let symbol: String
    let tint: Color
    @ViewBuilder let detail: () -> Detail

    init(title: String, isBusy: Bool, symbol: String, tint: Color,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.title = title
        self.isBusy = isBusy
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The spinner stands where the verdict will stand, so the row does
            // not jump sideways when the answer replaces it.
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                detail()
            }
            Spacer(minLength: 0)
        }
    }
}

/// A numbered step. Shared by the install walk-through and the Health one,
/// because two hand-rolled copies is how the numbers end up different sizes.
struct WatchStep: View {

    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.tint, in: Circle())
            Text(.init(text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The actual steps, because "install it from the Watch app" is not enough
/// detail for somebody who has never scrolled that list to the bottom.
///
/// This is the state no app can fix for itself: iOS gives an app no way to
/// install its own watch companion, so the screen's whole job is to say the
/// right words rather than to offer a button that cannot exist.
struct WatchInstallSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WatchStep(1, "Open the **Watch** app on this iPhone")
            WatchStep(2, "Tap **My Watch**, then scroll to **Available Apps**")
            WatchStep(3, "Find **openWater** and tap **Install**")

            Text("Already installed? Give it a moment — the watch reports in when it next connects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
