import OpenWaterCore
import SwiftData
import SwiftUI

/// The debrief, offered the moment a session ends.
///
/// Everything on this screen is something only the rider knows and only they
/// can supply — what the wind was actually doing, which board it was, whether
/// it was any good. Left to later it is never filled in: an hour after the fact
/// nobody remembers whether it was 18 or 22 knots, and a season of sessions
/// with no conditions attached is a season you cannot learn anything from.
///
/// So it appears once, straight after Save, with the numbers already on screen
/// so it feels like the end of the session rather than paperwork. Every field
/// is optional and Skip is a first-class button — a rider walking up the beach
/// in the dark should not have to argue with a form.
struct SessionReviewView: View {

    let stored: StoredSession

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var session: Session?
    @State private var edits: Session.Edits
    @State private var windDirectionText = ""
    @State private var windSpeedText = ""
    @State private var isSaving = false

    init(stored: StoredSession) {
        self.stored = stored
        _edits = State(initialValue: Session.Edits(
            sport: stored.sport,
            title: stored.title,
            spotName: stored.spotName,
            notes: stored.notes
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    headline
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack {
                        Text("Feeling")
                        Spacer()
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

                    Picker("Purpose", selection: Binding(
                        get: { edits.purpose ?? "" },
                        set: { edits.purpose = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Not set").tag("")
                        ForEach(SessionPurpose.suggestions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                } header: {
                    Text("How was it?")
                }

                Section {
                    TextField("Spot", text: Binding(
                        get: { edits.spotName ?? "" },
                        set: { edits.spotName = $0 }
                    ))
                    TextField("Title (optional)", text: Binding(
                        get: { edits.title ?? "" },
                        set: { edits.title = $0 }
                    ))
                } header: {
                    Text("Where")
                } footer: {
                    Text("The spot names this session in the list if you do not give it a title.")
                }

                Section {
                    HStack {
                        Text("Wind from")
                        Spacer()
                        TextField("—", text: $windDirectionText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("°").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Wind speed")
                        Spacer()
                        TextField("—", text: $windSpeedText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text(settings.units.speed.symbol).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Conditions")
                } footer: {
                    if let estimate = session?.effectiveWind, estimate.source.isEstimate {
                        Text("openWater guessed \(Format.bearing(estimate.directionFrom)) from the shape of your track. Correcting it here recalculates every angle, VMG and the polar.")
                    } else {
                        Text("Angles, VMG and the polar are all measured from the wind direction. It is worth thirty seconds while you still remember.")
                    }
                }

                Section("Notes") {
                    TextField("Gear, conditions, how it went…", text: $edits.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Session saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
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
                guard let data = library.archiveData(id: stored.id) else { return }
                let loaded = await Task.detached {
                    try? SessionArchive.decode(data).session
                }.value
                session = loaded
                if let loaded { edits = Session.Edits(session: loaded) }
            }
        }
    }

    /// What was just achieved, so the form reads as the end of the session
    /// rather than as a chore attached to it.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nice one.")
                .font(.title2.weight(.bold))

            HStack(alignment: .top, spacing: 0) {
                CardStat(
                    group: "Speed",
                    groupColour: .orange,
                    label: "Max \(settings.units.speed.symbol)",
                    value: Format.speed(stored.maxSpeed, unit: settings.units.speed,
                                        decimals: 1, includeSymbol: false)
                )
                CardStat(
                    group: "Distance",
                    groupColour: .blue,
                    label: settings.units.distance.symbol,
                    value: Format.distance(stored.distance, unit: settings.units.distance,
                                           includeSymbol: false)
                )
                CardStat(
                    group: "Duration",
                    groupColour: .teal,
                    label: stored.duration >= 3600 ? "h:m:s" : "m:s",
                    value: Format.duration(stored.duration)
                )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    // MARK: - Save

    @MainActor
    private func save() async {
        guard let session else { return }
        var edited = edits
        edited.windDirection = Double(windDirectionText.trimmingCharacters(in: .whitespaces))
            .map { Geo.normalizeDegrees($0) }
        edited.windSpeed = Double(windSpeedText.trimmingCharacters(in: .whitespaces))
            .map { settings.units.speed.toMetresPerSecond($0) }

        guard session.requiresReanalysis(for: edited) else {
            library.save(session.applying(edited, categories: settings.categories))
            dismiss()
            return
        }

        isSaving = true
        let categories = settings.categories
        let result = await Task.detached {
            session.applying(edited, categories: categories)
        }.value
        library.save(result)
        isSaving = false
        dismiss()
    }
}
