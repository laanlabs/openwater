import OpenWaterCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State private var selection: ScreenshotRoute.Tab = .sessions

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "list.bullet", value: ScreenshotRoute.Tab.sessions) {
                SessionListView()
            }
            Tab("Record", systemImage: "record.circle", value: ScreenshotRoute.Tab.record) {
                RecordTabView()
            }
            Tab("Bests", systemImage: "trophy", value: ScreenshotRoute.Tab.records) {
                RecordsView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: ScreenshotRoute.Tab.trends) {
                TrendsView()
            }
            Tab("Settings", systemImage: "gearshape", value: ScreenshotRoute.Tab.settings) {
                SettingsView()
            }
        }
        .onAppear {
            if let route = ScreenshotRoute.requested { selection = route.tab }
        }
    }
}

// MARK: - Session list

struct SessionListView: View {

    @Environment(SessionLibrary.self) private var library
    @Environment(PhoneSyncClient.self) private var sync
    @Environment(AppSettings.self) private var settings

    @Query(sort: \StoredSession.startDate, order: .reverse)
    private var sessions: [StoredSession]

    @State private var sportFilter: Sport?
    @State private var isImporting = false
    @State private var importMessage: String?

    /// The file currently awaiting sport confirmation, and the rest of the
    /// queue behind it — selecting several files at once is normal, and each one
    /// needs its own confirmation.
    @State private var currentImport: ImportedTrack?
    @State private var importQueue: [ImportedTrack] = []

    /// Navigation path, so a screenshot route can push a session without a tap.
    @State private var path: [UUID] = []

    /// Sessions swiped for deletion, held until confirmed.
    ///
    /// A session is an hour on the water that cannot be recreated, and a swipe
    /// is easy to do by accident while scrolling. Nothing is removed until the
    /// rider says so, and the prompt names what will go.
    @State private var pendingDeletion: [StoredSession] = []

    private var filtered: [StoredSession] {
        guard let sportFilter else { return sessions }
        return sessions.filter { $0.sport == sportFilter }
    }

    /// Sports actually present in the library, so the filter bar never offers a
    /// discipline with nothing behind it.
    private var availableSports: [Sport] {
        Array(Set(sessions.map(\.sport))).sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    EmptyLibraryView(isImporting: $isImporting)
                } else {
                    List {
                        Section {
                            if availableSports.count > 1 {
                                sportFilterBar
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(filtered) { session in
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session)
                                }
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let stored = library.session(id: id) {
                    SessionDetailView(stored: stored)
                }
            }
            .navigationTitle("Sessions")
            .onChange(of: sessions.count, initial: true) { _, _ in
                applyScreenshotRouteIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    watchStatus
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import…", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
                        Button("Add Demo Session", systemImage: "wand.and.stars") {
                            addDemoSession()
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                // `.data` is the catch-all: FIT files have no registered UTI on
                // most systems, and GPX/TCX arrive as anything from `.xml` to
                // `.item` depending on which app wrote them. The format is
                // detected from the contents, so accepting broadly here costs
                // nothing and stops files being greyed out in the picker.
                allowedContentTypes: [.data, .xml, .json, .commaSeparatedText],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(item: $currentImport, onDismiss: advanceImportQueue) { track in
                ImportView(imported: track) { sport in
                    // Building the session runs the full analysis, which on a
                    // three-hour FIT is a real amount of work — but it happens
                    // once, on an explicit action, and the result is cached.
                    library.save(track.makeSession(sport: sport))
                }
            }
            .confirmationDialog(
                "Delete session?",
                isPresented: Binding(
                    get: { !pendingDeletion.isEmpty },
                    set: { if !$0 { pendingDeletion = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { confirmDeletion() }
                Button("Keep", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text(deletionPrompt)
            }
            .alert("Import", isPresented: .constant(importMessage != nil)) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    // MARK: Pieces

    private var sportFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(title: "All", isOn: sportFilter == nil) { sportFilter = nil }
                ForEach(availableSports) { sport in
                    FilterChip(
                        title: sport.displayName,
                        systemImage: sport.symbolName,
                        isOn: sportFilter == sport
                    ) {
                        sportFilter = sportFilter == sport ? nil : sport
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    /// Watch connection state, shown plainly so a rider can tell at a glance
    /// whether a session is still sitting on their wrist.
    @ViewBuilder
    private var watchStatus: some View {
        if sync.isPaired && sync.isWatchAppInstalled {
            Image(systemName: sync.isReachable ? "applewatch" : "applewatch.slash")
                .foregroundStyle(sync.isReachable ? .green : .secondary)
                .accessibilityLabel(sync.isReachable ? "Watch connected" : "Watch not reachable")
        }
    }

    // MARK: Actions

    private func delete(at offsets: IndexSet) {
        pendingDeletion = offsets.map { filtered[$0] }
    }

    private func confirmDeletion() {
        for session in pendingDeletion { library.delete(session) }
        pendingDeletion = []
    }

    /// What the confirmation prompt calls the thing being deleted.
    private var deletionPrompt: String {
        guard let first = pendingDeletion.first else { return "" }
        if pendingDeletion.count == 1 {
            return "Delete \"\(first.displayTitle)\"? Its track and every metric go with it, and this cannot be undone."
        }
        return "Delete \(pendingDeletion.count) sessions? Their tracks and every metric go with them, and this cannot be undone."
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var archived = 0
            var queued: [ImportedTrack] = []
            var failures: [String] = []

            for url in urls {
                do {
                    // Archives already know their sport, so they skip the
                    // confirmation step entirely.
                    if let count = try library.importArchive(at: url) {
                        archived += count
                        continue
                    }
                    queued.append(try library.inspect(url))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            importQueue = queued
            advanceImportQueue()

            if !failures.isEmpty {
                importMessage = failures.joined(separator: "\n\n")
            } else if archived > 0, queued.isEmpty {
                importMessage = "Imported \(archived) session\(archived == 1 ? "" : "s")."
            }

        case .failure(let error):
            importMessage = error.localizedDescription
        }
    }

    /// Present the next file awaiting confirmation, if any.
    private func advanceImportQueue() {
        currentImport = importQueue.isEmpty ? nil : importQueue.removeFirst()
    }

    /// Push the first session when launched with a screenshot route that needs
    /// one. No-op in normal use — `ScreenshotRoute.requested` is nil unless the
    /// capture script passed the argument.
    private func applyScreenshotRouteIfNeeded() {
        guard let route = ScreenshotRoute.requested,
              route.opensSession,
              path.isEmpty,
              let first = sessions.first else { return }
        path = [first.id]
    }

    /// A synthetic session, so the app is explorable without getting wet.
    private func addDemoSession() {
        library.save(DemoData.wingSession(categories: settings.categories))
    }
}

// MARK: - Row

struct SessionRow: View {

    let session: StoredSession
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: session.sport.symbolName)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let subtitle = session.displaySubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                StatColumn(
                    label: "MAX",
                    value: Format.speed(session.maxSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false),
                    unit: settings.units.speed.symbol
                )
                StatColumn(
                    label: "500 m",
                    value: session.best500m > 0
                        ? Format.speed(session.best500m, unit: settings.units.speed,
                                       decimals: 1, includeSymbol: false)
                        : "—",
                    unit: settings.units.speed.symbol
                )
                StatColumn(
                    label: "DIST",
                    value: Format.distance(session.distance, unit: settings.units.distance),
                    unit: ""
                )
                StatColumn(
                    label: "TIME",
                    value: Format.duration(session.duration),
                    unit: ""
                )
            }

            if session.sport.isFoiling && session.flightCount > 0 {
                HStack(spacing: 10) {
                    Badge(
                        systemImage: "airplane",
                        text: "\(Int(session.foilingFraction * 100))% on foil"
                    )
                    if session.fallCount > 0 {
                        Badge(
                            systemImage: "figure.fall",
                            text: "\(session.fallCount) fall\(session.fallCount == 1 ? "" : "s")"
                        )
                    }
                    if session.gybeCount > 0 {
                        Badge(
                            systemImage: "arrow.triangle.turn.up.right.diamond",
                            text: "\(Int(session.dryGybeRate * 100))% dry"
                        )
                    }
                }
            }

        }
        .padding(.vertical, 4)
    }
}

// MARK: - Small components

struct StatColumn: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Badge: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

struct FilterChip: View {
    let title: String
    var systemImage: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: Capsule())
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyLibraryView: View {

    @Binding var isImporting: Bool
    @Environment(PhoneSyncClient.self) private var sync

    var body: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "water.waves")
        } description: {
            if sync.isPaired && sync.isWatchAppInstalled {
                Text("Record here or on your Apple Watch, or import a GPX, TCX or FIT file from another device.")
            } else {
                Text("Record a session on this iPhone, or import a GPX, TCX or FIT file from a Garmin, Coros, Suunto or another app.")
            }
        } actions: {
            VStack(spacing: 10) {
                Text("Use the Record tab to start one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import a file") { isImporting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
