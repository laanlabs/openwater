import OpenWaterCore
import SwiftUI

/// Confirms what an imported file actually is before it becomes a session.
///
/// This step exists because of a specific failure: a GPX or FIT from a watch
/// almost never states the sport, and the sport chooses every detection
/// threshold — takeoff speed, turn sharpness, plausible maximum. Import a wing
/// session as a kayak and the flights, gybes and falls all come out wrong, but
/// they come out *plausibly* wrong, which is worse than failing.
///
/// It is also the honest place to show what the file was missing. A GPX with no
/// Doppler speed will produce softer peaks than the same session recorded on the
/// watch, and the rider should know that before they compare the numbers.
struct ImportView: View {

    let imported: ImportedTrack
    let onImport: (Sport) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var sport: Sport

    init(imported: ImportedTrack, onImport: @escaping (Sport) -> Void) {
        self.imported = imported
        self.onImport = onImport
        // The rider's own last choice beats a constant. A file that does not
        // name its sport is the common case, and sport sets every threshold
        // for flights, turns and glides — so somebody importing a season of
        // wingfoil sessions should not have to correct the picker each time.
        _sport = State(initialValue: imported.sportHint
                       ?? UserDefaults.standard.string(forKey: "lastSport")
                           .flatMap(Sport.init(rawValue:))
                       ?? .wingfoil)
    }

    private let ordered: [Sport] = [
        .wingfoil, .parawing, .downwindSUP, .prone,
        .windfoil, .windsurf, .kitefoil, .kitesurf,
        .sail, .sup, .kayak, .efoil, .tow, .other,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Format", value: imported.format.displayName)
                    if let name = imported.name {
                        LabeledContent("Name", value: name)
                    }
                    LabeledContent("Points", value: "\(imported.points.count)")
                    if let start = imported.startDate {
                        LabeledContent(
                            "Recorded",
                            value: start.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let start = imported.startDate, let end = imported.endDate {
                        LabeledContent(
                            "Duration",
                            value: Format.duration(end.timeIntervalSince(start))
                        )
                    }
                } header: {
                    Text("File")
                }

                Section {
                    Picker("Sport", selection: $sport) {
                        ForEach(ordered) { sport in
                            Label(sport.displayName, systemImage: sport.symbolName)
                                .tag(sport)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Sport")
                } footer: {
                    if imported.sportHint == nil {
                        Text("This file does not say what sport it was. The sport sets the thresholds for detecting flights, gybes and falls, so it is worth getting right — you can change it later.")
                    } else {
                        Text("Taken from the file. Change it if it is wrong.")
                    }
                }

                dataQualitySection
            }
            .navigationTitle("Import session")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Import session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // In the bar rather than as the last row of the form. A file
                // with several warnings pushes that row below the fold, so the
                // one button the screen exists for was the one thing a rider
                // had to go looking for — and it sat opposite a Cancel that
                // was always visible.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(sport)
                        dismiss()
                    }
                    // Filled with the accent colour rather than left as text on
                    // the standard capsule. Cancel and Import otherwise look
                    // identical — same shape, same weight, same colour — and
                    // the one that does the thing the screen is for should not
                    // have to be found by reading.
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var dataQualitySection: some View {
        Section {
            HStack {
                Label(
                    imported.hasSpeedChannel ? "Speed channel present" : "No speed channel",
                    systemImage: imported.hasSpeedChannel ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(imported.hasSpeedChannel ? .green : .orange)
            }
            if imported.hasHeartRate {
                Label("Heart rate present", systemImage: "heart.fill")
                    .foregroundStyle(.secondary)
            }
            ForEach(imported.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What's in the file")
        } footer: {
            if !imported.hasSpeedChannel {
                Text("Without Doppler speed from the receiver, openWater works speeds out from position changes. That is fine for distance and averages, but peak figures will be softer than a watch recording — they are marked as derived so you can tell them apart.")
            }
        }
    }
}

/// Format picker for exporting one session.
/// One way of writing a session out.
///
/// Shared between the single-session sheet and bulk export, so the two can
/// never drift into offering different formats or different descriptions of
/// the same format.
struct ExportOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let make: (StoredSession, SessionLibrary, AppSettings) throws -> Data
    let fileExtension: String

    static let all: [ExportOption] = [
        ExportOption(
            id: "openwater",
            title: "openWater archive",
            detail: "Everything, losslessly. Use this to back up or move to another device.",
            symbol: "shippingbox",
            make: { s, l, a in try l.export(s, as: .openwater, privacy: .none) },
            fileExtension: "openwater"
        ),
        ExportOption(
            id: "gpx",
            title: "GPX",
            detail: "Understood by almost everything — Strava, Garmin Connect, Google Earth. Keeps speed and heart rate in extensions.",
            symbol: "point.topleft.down.to.point.bottomright.curvepath",
            make: { s, l, a in try l.export(s, as: .gpx, privacy: .none) },
            fileExtension: "gpx"
        ),
        ExportOption(
            id: "tcx",
            title: "TCX",
            detail: "Garmin's training format. Speed is part of the standard schema.",
            symbol: "doc.text",
            make: { s, l, a in try l.export(s, as: .tcx, privacy: .none) },
            fileExtension: "tcx"
        ),
        ExportOption(
            id: "csv",
            title: "CSV",
            detail: "One row per sample, every channel. For spreadsheets and your own analysis.",
            symbol: "tablecells",
            make: { s, l, a in try l.export(s, as: .csv, privacy: .none, units: a.units) },
            fileExtension: "csv"
        ),
        ExportOption(
            id: "geojson",
            title: "GeoJSON",
            detail: "For mapping tools. Includes a separate feature per flight and fall.",
            symbol: "map",
            make: { s, l, a in try l.exportGeoJSON(s, privacy: .none) },
            fileExtension: "geojson"
        ),
    ]

    /// A filename that sorts by date and says what it is.
    func filename(for stored: StoredSession) -> String {
        let stamp = stored.startDate.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        return "openWater-\(stored.sport.rawValue)-\(stamp).\(fileExtension)"
    }
}

struct ExportView: View {

    let stored: StoredSession

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var errorMessage: String?

    private var options: [ExportOption] { ExportOption.all }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options) { option in
                        Button {
                            export(option)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: option.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .font(.body)
                                    Text(option.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    // Exports used to apply the sharing trim, on the theory
                    // that anything leaving the phone deserved it. In practice
                    // an export is the rider's own backup or their own analysis
                    // in another tool, and silently cutting 400 m out of their
                    // data is the opposite of a backup. Sharing keeps the trim;
                    // exporting does not, and both say so.
                    Label(
                        "Complete data — nothing is trimmed or hidden. Web sharing is where the launch point gets masked.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                }

                if let url = exportURL {
                    Section {
                        ShareLink(item: url) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func export(_ option: ExportOption) {
        do {
            let data = try option.make(stored, library, settings)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(option.filename(for: stored))
            try data.write(to: url, options: .atomic)
            exportURL = url
            errorMessage = nil
        } catch {
            exportURL = nil
            errorMessage = error.localizedDescription
        }
    }
}
