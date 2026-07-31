import OpenWaterCore
import SwiftUI

/// Edit a session's sport, name and notes after the fact.
///
/// The important part is the sport. A session recorded on the wrong setting —
/// or imported from a file that never said — has flights, gybes and falls that
/// are not merely approximate but meaningless, and until now there was no way
/// to fix it. Changing it here re-runs the whole analysis.
///
/// Wind is the same story for angles, VMG and the polar, so it is editable too.
/// An *estimated* wind is deliberately not pre-filled into the field: showing it
/// there would turn a guess into something the rider appears to have asserted.
struct SessionEditView: View {

    let stored: StoredSession

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var edits: Session.Edits
    @State private var session: Session?
    @State private var windDirectionText = ""
    @State private var windSpeedText = ""
    @State private var isSaving = false

    init(stored: StoredSession) {
        self.stored = stored
        // Seeded from the stored row so the form is populated instantly; the
        // full session loads behind it for the re-analysis.
        _edits = State(initialValue: Session.Edits(
            sport: stored.sport,
            title: stored.title,
            spotName: stored.spotName,
            notes: stored.notes
        ))
    }

    private var willRecompute: Bool {
        guard let session else { return false }
        return session.requiresReanalysis(for: currentEdits)
    }

    /// The edits with the free-text wind fields folded in.
    private var currentEdits: Session.Edits {
        var result = edits
        result.windDirection = Double(windDirectionText.trimmingCharacters(in: .whitespaces))
            .map { Geo.normalizeDegrees($0) }
        result.windSpeed = Double(windSpeedText.trimmingCharacters(in: .whitespaces))
            .map { settings.units.speed.toMetresPerSecond($0) }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: Binding(
                        get: { edits.title ?? "" },
                        set: { edits.title = $0 }
                    ))
                    TextField("Spot", text: Binding(
                        get: { edits.spotName ?? "" },
                        set: { edits.spotName = $0 }
                    ))
                } header: {
                    Text("Name")
                } footer: {
                    Text("Both optional. Without a title, openWater shows the spot, and without that, the sport.")
                }

                Section {
                    SportRow(selection: $edits.sport)
                } header: {
                    Text("Sport")
                } footer: {
                    if edits.sport != stored.sport {
                        Label(
                            "Changing the sport recalculates this session — flights, gybes, falls and every speed category are detected using thresholds specific to it.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                windSection
                flyingSection

                Section {
                    Picker("Purpose", selection: Binding(
                        get: { edits.purpose ?? "" },
                        set: { edits.purpose = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Not set").tag("")
                        ForEach(SessionPurpose.suggestions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }

                    HStack {
                        Text("Feeling")
                        Spacer()
                        // Faces rather than a 1–5 picker: this is the one field
                        // in the app that is pure memory, and it should take a
                        // single tap on the way back to the car.
                        ForEach(Feeling.all, id: \.self) { value in
                            Button {
                                edits.feeling = edits.feeling == value ? nil : value
                            } label: {
                                Image(systemName: Feeling.symbol(for: value))
                                    .font(.title3)
                                    .foregroundStyle(edits.feeling == value
                                                     ? Feeling.colour(for: value)
                                                     : Color.secondary.opacity(0.45))
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Feeling.label(for: value))
                        }
                    }
                } header: {
                    Text("How it went")
                }

                Section("Notes") {
                    TextField("Gear, conditions, how it went…", text: $edits.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    LabeledContent("Recorded", value: stored.startDate.formatted(date: .long, time: .shortened))
                    LabeledContent("Duration", value: Format.duration(stored.duration))
                    LabeledContent("Distance", value: Format.distance(stored.distance, unit: settings.units.distance))
                    if let device = session?.deviceModel {
                        LabeledContent("Device", value: device)
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("The track itself is never changed by editing.")
                }
            }
            .navigationTitle("Edit session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(willRecompute ? "Save & Recalculate" : "Save") {
                        Task { await save() }
                    }
                    .disabled(session == nil || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Recalculating…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .task {
                let data = stored.archiveData
                let loaded = await Task.detached {
                    try? SessionArchive.decode(data).session
                }.value
                session = loaded
                if let loaded {
                    edits = Session.Edits(session: loaded)
                    if let direction = edits.windDirection {
                        windDirectionText = String(Int(direction.rounded()))
                    }
                    if let speed = edits.windSpeed {
                        windSpeedText = String(
                            format: "%.0f",
                            settings.units.speed.convert(fromMetresPerSecond: speed)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Wind

    @ViewBuilder
    private var windSection: some View {
        Section {
            HStack {
                Text("Direction")
                Spacer()
                TextField("—", text: $windDirectionText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("° from")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Speed")
                Spacer()
                TextField("—", text: $windSpeedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(settings.units.speed.symbol)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Wind")
        } footer: {
            if let estimate = session?.effectiveWind, estimate.source.isEstimate {
                Text("openWater worked out \(Format.bearing(estimate.directionFrom)) from the shape of your track (\(Int(estimate.confidence * 100))% confidence). Enter a direction here to override it — angles, VMG and the polar are all measured from it.")
            } else {
                Text("Direction the wind was coming from. Angles, VMG and the polar are measured from it. Leave blank to let openWater work it out from your track.")
            }
        }
    }

    // MARK: - Flying

    /// The speed this rider counts as flying.
    ///
    /// Offered per session rather than as one app-wide setting because it is a
    /// property of the kit, not the discipline: a big front wing under a light
    /// rider flies several knots below where a small one does, and "time on
    /// foil" measured against somebody else's board is a number about openWater
    /// rather than about the session.
    @ViewBuilder
    private var flyingSection: some View {
        if edits.sport.isFoiling {
            Section {
                Picker("Flying above", selection: Binding(
                    get: { edits.foilTakeoffSpeed ?? 0 },
                    set: { edits.foilTakeoffSpeed = $0 == 0 ? nil : $0 }
                )) {
                    Text("Default for \(edits.sport.displayName) (\(Format.speed(edits.sport.thresholds.foilTakeoffSpeed, unit: settings.units.speed, decimals: 1)))")
                        .tag(0.0)
                    ForEach(Self.thresholdChoices, id: \.self) { speed in
                        Text(Format.speed(speed, unit: settings.units.speed, decimals: 1))
                            .tag(speed)
                    }
                }
            } header: {
                Text("Flying")
            } footer: {
                Text("Time on foil, distance on foil, the longest flight and the flight count are all measured from this. Changing it recalculates them.")
            }
        }
    }

    /// 4.0 to 8.5 m/s in half-metre steps — roughly 8 to 16.5 knots, which
    /// covers every realistic takeoff from a big downwind board to a small
    /// high-aspect wing.
    private static let thresholdChoices: [Double] = stride(from: 4.0, through: 8.5, by: 0.5).map { $0 }

    // MARK: - Save

    private func save() async {
        guard let session else { return }
        let edited = currentEdits

        guard session.requiresReanalysis(for: edited) else {
            library.save(session.applying(edited, categories: settings.categories))
            dismiss()
            return
        }

        isSaving = true
        // Re-analysis on a long track is real work; keep it off the main actor
        // so the sheet stays responsive rather than freezing mid-save.
        let categories = settings.categories
        let result = await Task.detached {
            session.applying(edited, categories: categories)
        }.value
        library.save(result)
        isSaving = false
        dismiss()
    }
}
