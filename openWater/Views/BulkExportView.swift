import OpenWaterCore
import SwiftData
import SwiftUI

/// Export several sessions at once.
///
/// The single-session sheet is fine for sending one ride to a friend, but a
/// season is a hundred of them and nobody is tapping through that sheet a
/// hundred times. This is the same list of formats applied to a selection —
/// pick the format first, because it is the decision that determines whether
/// you want everything or just the good ones.
///
/// Files are handed to the share sheet as a set rather than zipped: iOS can put
/// a batch straight into Files, Mail or AirDrop, and a zip would only add a step
/// at the far end.
struct BulkExportView: View {

    let sessions: [StoredSession]

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportOption = ExportOption.all[1]   // GPX
    @State private var selection: Set<UUID> = []
    @State private var exported: [URL] = []
    @State private var isWorking = false
    @State private var problem: String?

    private var chosen: [StoredSession] {
        sessions.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportOption.all) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Text(format.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Format")
                } footer: {
                    Label(
                        "Complete data — nothing is trimmed. These files are your backup.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                }

                Section {
                    ForEach(sessions) { session in
                        row(session)
                    }
                } header: {
                    HStack {
                        Text("Sessions")
                        Spacer()
                        Button(selection.count == sessions.count ? "Deselect All" : "Select All") {
                            selection = selection.count == sessions.count
                                ? []
                                : Set(sessions.map(\.id))
                        }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                    }
                }

                if !exported.isEmpty {
                    Section {
                        ShareLink(items: exported) {
                            Label(
                                "Share \(exported.count) file\(exported.count == 1 ? "" : "s")",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                }

                if let problem {
                    Section {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Export Sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await export() } }
                        .disabled(chosen.isEmpty || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("Writing \(chosen.count) file\(chosen.count == 1 ? "" : "s")…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: format) { _, _ in exported = [] }
            .onChange(of: selection) { _, _ in exported = [] }
        }
    }

    private func row(_ session: StoredSession) -> some View {
        Button {
            if selection.contains(session.id) {
                selection.remove(session.id)
            } else {
                selection.insert(session.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.contains(session.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(session.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(session.startDate.formatted(date: .abbreviated, time: .omitted)) · \(Format.distance(session.distance, unit: settings.units.distance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: session.sport.symbolName)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Work

    @MainActor
    private func export() async {
        isWorking = true
        defer { isWorking = false }

        // Its own directory per run, so a second export does not hand the share
        // sheet a mixture of this batch and the last one.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openWater-export-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            problem = error.localizedDescription
            return
        }

        var urls: [URL] = []
        var failures = 0
        var used: Set<String> = []

        for session in chosen {
            do {
                let data = try format.make(session, library, settings)
                // Two sessions on one day in one sport collide otherwise, and
                // writing the second over the first would silently export fewer
                // files than were asked for.
                var name = format.filename(for: session)
                var attempt = 2
                while used.contains(name) {
                    let base = format.filename(for: session)
                        .replacingOccurrences(of: ".\(format.fileExtension)", with: "")
                    name = "\(base)-\(attempt).\(format.fileExtension)"
                    attempt += 1
                }
                used.insert(name)
                let url = directory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                failures += 1
            }
        }

        exported = urls
        // Said plainly rather than swallowed: an export that quietly produced
        // 97 of 100 files is worse than one that admits it.
        problem = failures == 0
            ? nil
            : "\(failures) session\(failures == 1 ? "" : "s") could not be written. The rest are ready to share."
    }
}

extension ExportOption: Hashable {
    static func == (lhs: ExportOption, rhs: ExportOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
