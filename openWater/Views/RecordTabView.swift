import CoreLocation
import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftData
import SwiftUI

/// The Record tab: a live map with a start button on it.
///
/// Recording was a modal reached from a toolbar button, which got the priority
/// backwards — it is the app's primary action and it happens in the least
/// forgiving conditions there are: on a beach, in a wetsuit, cold hands, phone
/// half-stowed in a pouch. A dedicated tab means it is always one reachable tap
/// away and never behind a sheet that has to be dismissed.
///
/// The map is open before recording starts because it answers the two questions
/// a rider actually has at that moment — has the GPS locked on, and is it
/// putting me where I am standing. A spinner saying "acquiring" answers neither.
struct RecordTabView: View {

    /// Whether this tab is the one on screen.
    ///
    /// The tab stays in the hierarchy when the rider looks at something else,
    /// and a live `Map` that nobody can see still holds MapKit's renderer open.
    /// The map is built only while the tab is actually visible.
    var isActive: Bool = true

    /// Bumped by the tab bar every time Record is tapped. Any change clears
    /// the pushed session so the rider lands on the screen that starts one.
    var reset: Int = 0

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(SpotGuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings

    /// The Start button and the live screen's controls are fixed at the bottom,
    /// so this screen keeps clear of the floating bar rather than drawing under
    /// it. The map behind them still runs the full height.
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var sport: Sport = .wingfoil
    @State private var title = ""
    @State private var spot = ""
    @State private var showingDetails = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showingCountdown = false

    /// Pushed after a session is saved, so the rider lands on what they just
    /// recorded instead of an empty Record tab.
    @State private var path: [UUID] = []

    /// The session just saved, awaiting its debrief.
    @State private var reviewing: StoredSession?

    /// Up when End was tapped and the library would not take the session.
    /// The recording is still on disk as a crash log, and the alert says so.
    @State private var saveFailed = false

    /// The model wind at the launch, as fetched. `recorder.wind` may hold the
    /// rider's correction on top of it; this keeps what the forecast said, so
    /// the wind setter can start from it when there is nothing else.
    @State private var launchWind: WindReading?
    @State private var launchSpotName: String?
    @State private var isSettingWind = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch recorder.state {
                case .idle:
                    idle
                case .recording, .paused, .finishing:
                    LiveSessionScreen(onEnd: end)
                }
            }
            .navigationTitle(recorder.state == .idle ? "Record" : sport.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Record")
            .toolbarVisibility(recorder.state == .idle ? .automatic : .hidden, for: .navigationBar)
            .toolbar {
                if recorder.state == .idle, isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy) {
                                camera = .userLocation(fallback: .automatic)
                            }
                        } label: {
                            Image(systemName: "location.fill")
                        }
                        .accessibilityLabel("Centre on my location")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let stored = library.session(id: id), !stored.isDeleted {
                    SessionDetailView(stored: stored)
                } else {
                    ContentUnavailableView(
                        "Session no longer available",
                        systemImage: "questionmark.folder"
                    )
                }
            }
            .onAppear {
                if recorder.state == .idle { sport = settings.lastSport }
                recorder.allTimeBests = library.records.mapValues(\.speed)
                if isActive { recorder.warmUpSensors() }
                Task { await recorder.prepare(isAlreadySaved: { library.session(id: $0) != nil }) }
            }
            // The tab stays in the hierarchy when the rider looks at something
            // else, so `onDisappear` never fires — and the receiver stayed on.
            .onChange(of: reset) { _, _ in
                // Only the stack is cleared. A recording in progress is left
                // exactly alone — tapping Record mid-session should show the
                // live screen, which is what popping to the root does anyway.
                path = []
            }
            .onChange(of: isActive) { _, active in
                if active {
                    recorder.warmUpSensors()
                } else if recorder.state == .idle {
                    recorder.stopWarmUp()
                }
            }
            .sheet(isPresented: $showingCountdown) {
                CountdownView(onStart: start)
            }
            .sheet(item: $reviewing) { stored in
                SessionReviewView(stored: stored)
            }
            // An interrupted session, offered back. A sheet over whatever is
            // showing, so it cannot be missed and cannot be lost to a scroll.
            // The watch has had this since the beginning; the phone found its
            // logs at every launch and never told anyone.
            .sheet(item: recoveryBinding) { candidate in
                RecoverySheet(candidate: candidate, onRecovered: open)
            }
            .alert("Couldn't save that session", isPresented: $saveFailed) {
                Button("OK") {}
            } message: {
                Text("The recording is still on this iPhone. It will be offered back the next time you open Record.")
            }
        }
    }

    /// The prompt shows only while nothing is being recorded — a log from
    /// last time has no business interrupting this time.
    private var recoveryBinding: Binding<RecordingEngine.RecoverableSession?> {
        Binding(
            get: { recorder.state == .idle ? recorder.recoverable : nil },
            set: { _ in }
        )
    }

    // MARK: - Before starting

    private var idle: some View {
        // A bottom-aligned stack rather than a `safeAreaInset`, and the reason
        // is a geometry trap worth remembering. The map has to run to the
        // bottom of the screen, so it ignores the safe area — but a
        // `safeAreaInset` attached after that places its content against the
        // *ignored* edge, i.e. the physical bottom, while the tab bar sits
        // above the home indicator. Padding by the bar's height then lands the
        // Start button a home indicator's worth too low, which is exactly
        // where it was hiding.
        //
        // Here the stack keeps the safe area, so the controls start above the
        // home indicator and the padding lifts them clear of the bar. Only the
        // map ignores it.
        ZStack(alignment: .bottom) {
            Group {
                if isActive {
                    Map(position: $camera) {
                        UserAnnotation()
                    }
                    .mapStyle(settings.mapStyle.mapStyle)
                    // MapKit lays its own controls out inside the map's safe
                    // area, and this map has none — it runs to the physical
                    // edges by design, so the buttons went with it and sat up
                    // under the status bar. Ours lives in the toolbar, which
                    // cannot land outside the safe area whatever the map does.
                    .mapControlVisibility(.hidden)
                } else {
                    Color(.systemGroupedBackground)
                }
            }
            .ignoresSafeArea()

            controls
                .padding(.bottom, tabBarHeight)
        }
        .task(id: Self.coordinateKey(recorder.location.lastCoordinate)) {
            await loadLaunchWind()
        }
        .sheet(isPresented: $isSettingWind) {
            WindSetterView(initialWind: recorder.wind ?? launchWind.map(windFromReading),
                           initialSwell: recorder.swellHeight,
                           initialSwellDirection: recorder.swellDirection,
                           showsSwell: true) { direction, speed, swell, swellFrom in
                recorder.wind = Wind(directionFrom: direction, speed: speed,
                                     source: .manual, confidence: 1)
                recorder.swellHeight = swell
                recorder.swellDirection = swellFrom
            }
        }
    }

    /// Re-runs the launch-wind lookup when the position changes meaningfully,
    /// not on every fix. `task(id:)` compares this key, so it is rounded —
    /// about a kilometre, comfortably inside the grid the forecast comes on.
    private static func coordinateKey(_ coordinate: Geo.Coordinate?) -> String {
        guard let coordinate else { return "none" }
        return String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    /// The model wind at the launch, named after the nearest guide spot.
    ///
    /// Shown before Start and attached to the session as an external reading
    /// unless the rider adjusts it — in which case their word wins. Either
    /// way the session starts with a wind instead of hoping the track shape
    /// gives one up afterwards.
    private func loadLaunchWind() async {
        guard recorder.state == .idle, let here = recorder.location.lastCoordinate else { return }
        await guide.load()
        launchSpotName = guide.nearestSpot(to: here).flatMap { spot in
            Geo.distance(here, .init(latitude: spot.latitude, longitude: spot.longitude)) < 3000
                ? spot.name : nil
        }
        guard let reading = await guide.currentWind(at: here) else { return }
        launchWind = reading
        // Never overwrite the rider's own setting.
        if recorder.wind == nil || recorder.wind?.source == .external {
            recorder.wind = windFromReading(reading)
        }
    }

    private func windFromReading(_ reading: WindReading) -> Wind {
        Wind(directionFrom: reading.directionDeg, speed: reading.speedKn / 1.94384,
             source: .external, confidence: 0.6)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            windChip

            HStack(spacing: 10) {
                Menu {
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.recordable) { option in
                            Label(option.displayName, systemImage: option.symbolName)
                                .tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sport.symbolName)
                        Text(sport.displayName)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                }

                gpsPill

                Spacer(minLength: 0)

                Button {
                    withAnimation(.snappy) { showingDetails.toggle() }
                } label: {
                    Image(systemName: showingDetails ? "textformat" : "textformat.alt")
                        .font(.subheadline)
                        .padding(11)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Name this session")
            }

            if showingDetails {
                VStack(spacing: 8) {
                    TextField("Title (optional)", text: $title)
                    TextField("Spot (optional)", text: $spot)
                }
                .textFieldStyle(.roundedBorder)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 10) {
                Button {
                    start()
                } label: {
                    Text("Start")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!canStart)

                // Racing starts on somebody else's gun, not on a tap. The
                // countdown is beside Start rather than buried in a menu
                // because on a start line there is no time to go looking.
                Button {
                    showingCountdown = true
                } label: {
                    Image(systemName: "flag.checkered")
                        .font(.title3)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Race start countdown")
            }

            if recorder.location.authorization == .denied {
                Text("openWater needs location access to record. Enable it in the Settings app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !recorder.location.hasFix {
                // Starting before the receiver settles is the most common way to
                // ruin a session's numbers, so it is said here rather than
                // discovered afterwards.
                Text("Waiting for a GPS fix — starting now would leave the first minute inaccurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        // On an iPad the map can run to the horizon, but a Start button the
        // width of the window is a banner, not a button. The controls keep a
        // phone's width and sit centred over the map.
        .frame(maxWidth: 520)
    }

    private var gpsPill: some View {
        let accuracy = recorder.location.latestAccuracy
        let good = accuracy >= 0 && accuracy <= 10
        return HStack(spacing: 5) {
            Image(systemName: recorder.location.hasFix ? "location.fill" : "location")
                .font(.caption)
                .foregroundStyle(good ? .green : .orange)
            Text(recorder.location.hasFix && accuracy >= 0
                 ? String(format: "±%.0f m", accuracy)
                 : "…")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var canStart: Bool {
        switch recorder.location.authorization {
        case .denied, .restricted: false
        default: true
        }
    }

    // MARK: - Actions

    private func start() {
        // Leaving the last session's detail on the stack would hide the live
        // screen behind it for the whole of the next recording.
        path = []
        settings.lastSport = sport
        recorder.autoPauseEnabled = settings.autoPauseWhileRecording
        recorder.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        recorder.spotName = spot.trimmingCharacters(in: .whitespaces).isEmpty ? nil : spot
        recorder.start(sport: sport)
    }

    /// The wind this session will start with, and the way to correct it.
    @ViewBuilder
    private var windChip: some View {
        if let wind = recorder.wind {
            Button {
                isSettingWind = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(wind.directionFrom))
                    Text("\(Format.cardinal(wind.directionFrom)) \(Int(wind.directionFrom.rounded()))°"
                         + (wind.speed.map { " · \(Format.speed($0, unit: settings.units.speed, decimals: 0))" } ?? ""))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(wind.source == .manual ? "set by you"
                         : "forecast\(launchSpotName.map { " · \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "pencil.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        } else if recorder.location.lastCoordinate != nil {
            Button {
                isSettingWind = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wind")
                    Text("Set the wind")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "pencil.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func end() {
        Task { await finishAndOpen() }
    }

    /// The analysis runs off the main actor; the live screen stays up,
    /// showing `.finishing`, until the session is built and saved.
    private func finishAndOpen() async {
        // Landing back on an empty Record tab after an hour on the water is the
        // wrong answer to "what did I just do?" — the session opens instead,
        // with the debrief over it while the conditions are still fresh.
        var stored: StoredSession?
        var persisted = false
        await recorder.finish { session in
            let result = library.save(session)
            stored = result.stored
            persisted = result.persisted
            return persisted
        }
        if let stored, persisted {
            open(stored)
        } else if stored != nil || recorder.recoverable != nil {
            // The engine kept the log because the save said no. Say so, rather
            // than opening a debrief on a session that is not there — and
            // look again now, so the recovery prompt follows the alert
            // instead of waiting for the next launch.
            saveFailed = true
            await recorder.prepare(isAlreadySaved: { library.session(id: $0) != nil })
        }
        title = ""
        spot = ""
        showingDetails = false
        // The next session gets a fresh forecast, not this one's leftovers —
        // manual or otherwise.
        recorder.wind = nil
        recorder.swellHeight = nil
        recorder.swellDirection = nil
        launchWind = nil
    }

    /// Land on a session just saved — by End, or by recovery.
    private func open(_ stored: StoredSession) {
        path = [stored.id]
        reviewing = stored
    }
}

/// Offered when a previous session was cut short before it was saved.
private struct RecoverySheet: View {

    let candidate: RecordingEngine.RecoverableSession
    var onRecovered: (StoredSession) -> Void

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var failedToSave = false
    @State private var isRecovering = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Unfinished session", systemImage: "arrow.clockwise.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)

                Text("openWater stopped before this session was saved. The track is still on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Sport", value: candidate.sport.displayName)
                    LabeledContent("Started", value: candidate.startDate.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Duration", value: Format.duration(candidate.duration))
                    LabeledContent("Distance", value: Format.distance(candidate.distance, unit: settings.units.distance))
                }
                .font(.subheadline)

                if failedToSave {
                    Text("Couldn't save that just now — the recording is untouched. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button {
                    isRecovering = true
                    Task {
                        // Dismissed only once the session is genuinely in
                        // the library. A failed write leaves the log alone
                        // and the prompt up, so the rider can try again
                        // rather than watch their one copy disappear into a
                        // tap.
                        var stored: StoredSession?
                        let session = await recorder.recover(candidate) { session in
                            let result = library.save(session)
                            stored = result.stored
                            return result.persisted
                        }
                        isRecovering = false
                        if session != nil, let stored {
                            dismiss()
                            onRecovered(stored)
                        } else {
                            failedToSave = true
                        }
                    }
                } label: {
                    Group {
                        if isRecovering {
                            ProgressView().tint(.white)
                        } else {
                            Text("Recover")
                        }
                    }
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                .disabled(isRecovering)

                Button("Discard", role: .destructive) {
                    Task {
                        await recorder.dismissRecovery()
                        dismiss()
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(isRecovering)
            }
            .padding(24)
            .navigationTitle("Recover session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
