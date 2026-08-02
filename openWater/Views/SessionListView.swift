import OpenWaterCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The session library: what you did, newest first.
///
/// Two things drive the layout. A rider opening the app after a session wants
/// the totals — how fast, how far, how much of it — before they want any one
/// session; and they find a particular session by the shape of its track, not
/// by reading dates. So: statistics on top, map-first cards below.
struct SessionListView: View {

    @Environment(SessionLibrary.self) private var library
    @Environment(PhoneSyncClient.self) private var sync
    @Environment(AppSettings.self) private var settings

    @Query(sort: \StoredSession.startDate, order: .reverse)
    private var allRows: [StoredSession]

    /// Everything except what is sitting in Recently Deleted.
    ///
    /// Filtered here rather than in the `@Query` predicate: SwiftData's
    /// predicate support for optionals is fussy, the list already filters in
    /// memory for period and sport, and a library is hundreds of rows, not
    /// millions.
    private var sessions: [StoredSession] { allRows.filter { !$0.isTrashed } }

    private var trashed: [StoredSession] { allRows.filter(\.isTrashed) }

    @State private var sportFilter: Sport?
    @State private var period: Period = .allTime
    @State private var sort: SortOrder = .newest
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
    @State private var showingTrash = false
    @State private var showingBulkExport = false
    @State private var showingWatchStatus = false

    enum Period: String, CaseIterable, Identifiable {
        case allTime = "All time"
        case year = "This year"
        case ninety = "Last 90 days"
        case thirty = "Last 30 days"

        var id: String { rawValue }

        func includes(_ date: Date, now: Date = Date()) -> Bool {
            switch self {
            case .allTime: true
            case .year: Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            case .ninety: date > now.addingTimeInterval(-90 * 86_400)
            case .thirty: date > now.addingTimeInterval(-30 * 86_400)
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        case fastest = "Fastest first"
        case longest = "Longest distance"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .newest: "arrow.down"
            case .oldest: "arrow.up"
            case .fastest: "bolt"
            case .longest: "ruler"
            }
        }
    }

    private var filtered: [StoredSession] {
        let matching = sessions.filter { session in
            period.includes(session.startDate)
                && (sportFilter == nil || session.sport == sportFilter)
        }
        switch sort {
        case .newest: return matching
        case .oldest: return matching.reversed()
        case .fastest: return matching.sorted { $0.maxSpeed > $1.maxSpeed }
        case .longest: return matching.sorted { $0.distance > $1.distance }
        }
    }

    /// Sports actually present in the library, so the filter never offers a
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
                    list
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let stored = library.session(id: id), !stored.isDeleted {
                    SessionDetailView(stored: stored)
                } else {
                    // The session went away while its detail was on screen.
                    // Saying so beats an empty screen with no explanation.
                    ContentUnavailableView(
                        "Session no longer available",
                        systemImage: "questionmark.folder"
                    )
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: sessions.count, initial: true) { _, _ in
                applyScreenshotRouteIfNeeded()
            }
            .toolbar { toolbar }
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
            .sheet(isPresented: $showingBulkExport) {
                // The filtered set, not the whole library: a rider who has
                // narrowed to "wingfoil, this year" has already said what they
                // mean, and re-picking it inside the sheet would be busywork.
                BulkExportView(sessions: filtered)
            }
            .sheet(isPresented: $showingTrash) {
                NavigationStack {
                    RecentlyDeletedView(sessions: trashed)
                }
            }
            .sheet(isPresented: $showingWatchStatus) {
                NavigationStack {
                    ScrollView { WatchStatusView().padding() }
                        .navigationTitle("Apple Watch")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingWatchStatus = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Import", isPresented: .constant(importMessage != nil)) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                LibraryStatsCard(sessions: filtered, period: period)

                filterRow

                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Nothing in this range",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No sessions match the filters above.")
                    )
                    .padding(.top, 30)
                }

                ForEach(filtered) { session in
                    NavigationLink(value: session.id) {
                        SessionCard(session: session)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDeletion = [session]
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { option in Text(option.rawValue).tag(option) }
                }
            } label: {
                FilterLabel(text: period.rawValue)
            }

            Menu {
                Picker("Activity", selection: $sportFilter) {
                    Text("All activities").tag(Sport?.none)
                    ForEach(availableSports) { sport in
                        Label(sport.displayName, systemImage: sport.symbolName)
                            .tag(Sport?.some(sport))
                    }
                }
            } label: {
                FilterLabel(text: sportFilter?.displayName ?? "All activities")
            }

            Spacer(minLength: 0)

            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { option in
                        Label(option.rawValue, systemImage: option.symbol).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.medium))
                    .padding(9)
                    .background(.background, in: Circle())
            }
            .accessibilityLabel("Sort sessions")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                if !sessions.isEmpty {
                    Button("Export Sessions…", systemImage: "square.and.arrow.up.on.square") {
                        showingBulkExport = true
                    }
                }
                if !trashed.isEmpty {
                    Divider()
                    Button("Recently Deleted (\(trashed.count))", systemImage: "trash") {
                        showingTrash = true
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    /// Watch state, always visible and always tappable.
    ///
    /// It was a passive icon that appeared only once everything already worked
    /// — which is precisely when nobody needs it. The case that matters is the
    /// rider who has a watch and no app on it yet, so the icon is now there in
    /// every state and opens the screen that explains how to fix whichever one
    /// they are in.
    private var watchStatus: some View {
        Button {
            showingWatchStatus = true
        } label: {
            Image(systemName: watchSymbol)
                .foregroundStyle(watchTint)
        }
        .accessibilityLabel("Apple Watch")
        .accessibilityValue(watchState.title)
    }

    private var watchState: WatchStatusView.State {
        if !sync.isPaired { return .noWatch }
        if !sync.isWatchAppInstalled { return .notInstalled }
        return sync.isReachable ? .connected : .installedNotReachable
    }

    private var watchSymbol: String { watchState.symbol }

    private var watchTint: Color {
        switch watchState {
        case .connected: .green
        case .notInstalled: .orange
        default: .secondary
        }
    }

    // MARK: - Actions

    private func confirmDeletion() {
        let removed = Set(pendingDeletion.map(\.id))
        for session in pendingDeletion { library.delete(session) }
        pendingDeletion = []
        path.removeAll { removed.contains($0) }
    }

    /// What the confirmation prompt calls the thing being deleted.
    private var deletionPrompt: String {
        guard let first = pendingDeletion.first else { return "" }
        if pendingDeletion.count == 1 {
            return "\"\(first.displayTitle)\" moves to Recently Deleted, where you can get it back for 30 days."
        }
        return "\(pendingDeletion.count) sessions move to Recently Deleted, where you can get them back for 30 days."
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

// MARK: - Statistics

/// Everything in the current filter, added up.
///
/// Deliberately built from the denormalised columns rather than from decoded
/// sessions: this has to recompute instantly every time a filter changes, and
/// decoding a season of archives to add four numbers would make the whole
/// screen feel broken.
struct LibraryStatsCard: View {

    let sessions: [StoredSession]
    let period: SessionListView.Period

    @Environment(AppSettings.self) private var settings

    @State private var showingNotes = false

    private var maxSpeed: Double { sessions.map(\.maxSpeed).max() ?? 0 }
    private var distance: Double { sessions.reduce(0) { $0 + $1.distance } }
    private var duration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }

    /// Distance over moving time, not the mean of the per-session averages —
    /// a five-minute session should not weigh as much as a three-hour one.
    private var averageSpeed: Double {
        let moving = sessions.reduce(0) { $0 + $1.movingTime }
        let covered = sessions.reduce(0.0) { $0 + $1.distance * ($1.movingTime / max($1.duration, 1)) }
        return moving > 0 ? covered / moving : 0
    }

    private var daySpan: Int {
        guard let first = sessions.map(\.startDate).min(),
              let last = sessions.map(\.startDate).max() else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return days + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your Statistics")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(period.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Adding up a season is its own set of choices — see the sheet.
                Button {
                    showingNotes = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How these statistics are worked out")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 0) {
                CardStat(
                    group: "Speed",
                    groupColour: .orange,
                    label: "Max \(settings.units.speed.symbol)",
                    value: Format.speed(maxSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false)
                )
                CardStat(
                    group: " ",
                    groupColour: .orange,
                    label: "Average \(settings.units.speed.symbol)",
                    value: Format.speed(averageSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false)
                )
            }
            .padding(.horizontal, 14)
            .sheet(isPresented: $showingNotes) {
                LibraryStatsNotesView(sessions: sessions, period: period)
            }

            Divider().padding(.vertical, 12)

            HStack(alignment: .top, spacing: 0) {
                CardStat(
                    group: "Distance",
                    groupColour: .blue,
                    label: settings.units.distance.symbol,
                    value: Format.distance(distance, unit: settings.units.distance,
                                           includeSymbol: false)
                )
                CardStat(
                    group: "Duration",
                    groupColour: .teal,
                    label: "h, m",
                    value: Format.duration(duration)
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.darkGray))
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
    }

    private var summary: String {
        let count = sessions.count
        guard count > 0 else { return "No sessions in this range yet." }
        let days = daySpan
        return "You have done: \(count) session\(count == 1 ? "" : "s") in \(days) day\(days == 1 ? "" : "s")"
    }
}

// MARK: - Small pieces

struct FilterLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.subheadline)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background, in: Capsule())
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
