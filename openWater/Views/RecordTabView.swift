import CoreLocation
import MapKit
import OpenWaterCore
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

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings

    @State private var sport: Sport = .wingfoil
    @State private var title = ""
    @State private var spot = ""
    @State private var showingDetails = false
    @State private var showingEndConfirmation = false
    @State private var showingDiscardConfirmation = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showingCountdown = false

    /// Pushed after a session is saved, so the rider lands on what they just
    /// recorded instead of an empty Record tab.
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch recorder.state {
                case .idle:
                    idle
                case .recording, .paused, .finishing:
                    LiveSessionScreen(showingEndConfirmation: $showingEndConfirmation)
                }
            }
            .navigationTitle(recorder.state == .idle ? "Record" : sport.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(recorder.state == .idle ? .automatic : .hidden, for: .navigationBar)
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
                recorder.prepare()
                recorder.warmUpSensors()
                recorder.allTimeBests = library.records.mapValues(\.speed)
            }
            .sheet(isPresented: $showingCountdown) {
                CountdownView(onStart: start)
            }
            .confirmationDialog("End session?", isPresented: $showingEndConfirmation) {
                Button("End & Save") { end() }
                Button("Discard…", role: .destructive) { showingDiscardConfirmation = true }
                Button("Keep Recording", role: .cancel) {}
            }
            // Discard sat one row below End & Save, and a mis-tap threw away
            // an hour on the water that cannot be recorded again. It asks twice
            // now, and says what is being lost.
            .confirmationDialog(
                "Discard this session?",
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard Session", role: .destructive) { recorder.discard() }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("\(Format.duration(recorder.metrics.duration)) and \(Format.distance(recorder.metrics.distance, unit: settings.units.distance)) will be deleted. This cannot be undone.")
            }
        }
    }

    // MARK: - Before starting

    private var idle: some View {
        Group {
            if isActive {
                Map(position: $camera) {
                    UserAnnotation()
                }
                .mapStyle(settings.mapStyle.mapStyle)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        // An inset rather than a bottom-aligned overlay: the map runs under the
        // controls, but the controls themselves stay above whatever the app
        // puts below them — which is how Start stopped hiding behind the tab
        // bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            WatchPill()
            WeatherCard(coordinate: recorder.location.lastCoordinate, units: settings.units)

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

    private func end() {
        // Landing back on an empty Record tab after an hour on the water is the
        // wrong answer to "what did I just do?" — the session opens instead.
        if let session = recorder.finish() {
            let stored = library.save(session)
            path = [stored.id]
        }
        title = ""
        spot = ""
        showingDetails = false
    }
}
