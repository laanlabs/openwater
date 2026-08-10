import OpenWaterCore
import SwiftData
import SwiftUI

struct SettingsView: View {

    @Environment(SessionLibrary.self) private var library
    @Environment(PhoneSyncClient.self) private var sync
    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var newDistance = ""
    @State private var distanceProblem: String?
    @State private var justAdded: Double?
    @FocusState private var distanceFieldFocused: Bool
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var recomputeMessage: String?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Speed", selection: $settings.units.speed) {
                        ForEach(SpeedUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    Picker("Distance", selection: $settings.units.distance) {
                        Text("Metric (km)").tag(DistanceUnit.metric)
                        Text("Nautical (NM)").tag(DistanceUnit.nautical)
                        Text("Imperial (mi)").tag(DistanceUnit.imperial)
                    }
                    Picker("Temperature", selection: Binding(
                        get: { settings.units.temperatureUnit },
                        set: { settings.units.temperature = $0 }
                    )) {
                        ForEach(TemperatureUnit.allCases) {
                            Text("\($0.title) (\($0.symbol))").tag($0)
                        }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("Set from your phone the first time the app runs. Speed stays in "
                         + "knots whatever you pick — it is what the sport is measured in "
                         + "everywhere, and a figure in mph is not comparable with anyone else's.")
                }

                Section {
                    NavigationLink {
                        SportSettingsView()
                    } label: {
                        Label("Sports", systemImage: "figure.surfing")
                    }
                } footer: {
                    Text("What counts as flying, as moving, and as a turn — per sport, because a foil that lifts at eight knots for one rider lifts at eleven for another.")
                }

                customWindowsSection

                Section {
                    Toggle("Trim start and end of shared tracks", isOn: $settings.sharingPrivacy.maskEndpoints)
                    if settings.sharingPrivacy.maskEndpoints {
                        Stepper(
                            "Trim \(Int(settings.sharingPrivacy.endpointMaskRadius)) m",
                            value: $settings.sharingPrivacy.endpointMaskRadius,
                            in: 50...1000,
                            step: 50
                        )
                    }
                    Toggle("Include heart rate", isOn: $settings.sharingPrivacy.includeHeartRate)
                    Toggle("Include spot name", isOn: $settings.sharingPrivacy.includeSpotName)
                    Toggle("Round times to the minute", isOn: $settings.sharingPrivacy.coarsenTimestamps)
                } header: {
                    Text("Privacy when sharing")
                } footer: {
                    Text("The start and end of a track are usually your car or your home, and they are the part of a shared file that identifies where you launch. Trimming them is on by default for anything you share, and your own copy is never changed.\n\nThis is not an exclusion zone: if you sail back over your launch point during a session, those passes stay in the track.")
                }

                Section {
                    NavigationLink {
                        QuiverView()
                    } label: {
                        Label("Quiver", systemImage: "bag")
                    }
                } footer: {
                    Text("Your boards, foils and wings — offered when tagging a session.")
                }

                Section {
                    NavigationLink {
                        ScrollView { WatchStatusView().padding() }
                            .navigationTitle("Apple Watch")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Apple Watch", systemImage: "applewatch")
                    }
                }

                Section {
                    WeatherStatusView()
                } header: {
                    Text("Weather")
                } footer: {
                    Text("Apple's weather service supplies the conditions on the Record tab and the observed wind offered for a saved session. Without it a session's wind is estimated from the shape of the track, and every angle and polar figure is measured from that estimate.\n\nIt is a model on a roughly 2 km grid, not an anemometer on the beach.")
                }

                Section {
                    Button("Export all sessions") { exportAll() }
                    if !library.staleSessions().isEmpty {
                        Button("Recompute \(library.staleSessions().count) session(s)") {
                            Task {
                                let count = await library.recomputeStaleSessions(overrides: settings.sportOverrides)
                                recomputeMessage = "Recomputed \(count) session\(count == 1 ? "" : "s")."
                            }
                        }
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Exports are complete — every sample and every channel, in the documented openWater format. Nothing about this app requires an account, and nothing leaves this device unless you send it.")
                }

                Section {
                    LabeledContent("Analysis version", value: "\(SessionSummary.currentVersion)")
                    Link(destination: URL(string: "https://github.com/laanlabs/openwater")!) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Every feature is free, including the ones other apps charge for — the full speed categories, foiling analysis, gybe and tack analysis, session replay and the race countdown. There is no subscription, no trial and no account.\n\nDetected events — flights, gybes, falls, jumps — are labelled with a confidence and can be wrong. The raw samples are always kept so any number can be checked.")
                }
            }
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
            .navigationTitle("Settings")
            // A decimal pad has no return key, so without a way out the
            // keyboard stayed up through scrolling and even a tab switch,
            // sitting over the rest of Settings. Two ways out, because there
            // was none.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Our own bar rather than `ToolbarItemGroup(placement:
                // .keyboard)`, which renders nothing inside this app's custom
                // tab container — the system accessory never appeared no matter
                // which view it was attached to. A safe-area inset is drawn by
                // us, above the keyboard, and cannot silently fail to exist.
                if distanceFieldFocused {
                    HStack {
                        Spacer()
                        Button("Done") { distanceFieldFocused = false }
                            .font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.snappy, value: distanceFieldFocused)
            .onChange(of: newDistance) { _, _ in distanceProblem = nil }
            .alert("Done", isPresented: .constant(recomputeMessage != nil)) {
                Button("OK") { recomputeMessage = nil }
            } message: {
                Text(recomputeMessage ?? "")
            }
            .sheet(isPresented: $isExporting) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export openWater archive", systemImage: "square.and.arrow.up")
                    }
                    .padding()
                    .presentationDetents([.medium])
                }
            }
        }
    }

    /// Custom windows — the "max speed over X km" a rider actually cares about.
    ///
    /// Adding one recomputes from the stored track, so it works retroactively on
    /// every session ever recorded rather than only on future ones.
    ///
    /// This section used to take metres and nothing else, silently reject
    /// anything under fifty, and clear the field either way. Somebody wanting a
    /// 1 km window typed "1", watched it vanish, and had no way of knowing
    /// whether it had worked — with a number pad up that they could not dismiss,
    /// because a number pad has no return key and nothing here provided one.
    /// Every part of that is fixed below: entry in the rider's own unit, one-tap
    /// presets for the distances people actually use, a reason shown when a
    /// value is refused, and a keyboard that closes.
    private var customWindowsSection: some View {
        @Bindable var settings = settings

        return Section {
            ForEach(settings.customDistances.sorted(), id: \.self) { metres in
                HStack {
                    Text(SpeedCategory.distance(metres: metres).shortName)
                    if metres == justAdded {
                        // Confirmation the row on screen is the one you just
                        // asked for — a list that silently grew by one is easy
                        // to miss, especially below the keyboard.
                        Text("Added")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        settings.customDistances.removeAll { $0 == metres }
                    }
                    .font(.caption)
                }
            }

            HStack {
                TextField("Distance", text: $newDistance)
                    .keyboardType(.decimalPad)
                    .focused($distanceFieldFocused)
                    .onSubmit(addCustomDistance)

                Text(settings.units.distance.symbol)
                    .foregroundStyle(.secondary)
                Button("Add", action: addCustomDistance)
                    .disabled(Double(newDistance.trimmingCharacters(in: .whitespaces)) == nil)
            }

            if let distanceProblem {
                Label(distanceProblem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // The distances people ask for, one tap, no typing and no unit
            // arithmetic.
            HStack(spacing: 8) {
                ForEach(presetDistances, id: \.metres) { preset in
                    Button(preset.label) { add(metres: preset.metres) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.caption)
                        .disabled(settings.customDistances.contains(preset.metres))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Custom distances")
        } footer: {
            Text("Add any distance you want a best speed over. Adding one recalculates from your stored tracks, so it applies to every session you already have.")
        }
    }

    /// Sensible presets in whichever unit the rider reads.
    private var presetDistances: [(label: String, metres: Double)] {
        let unit = settings.units.distance
        let per = unit.metresPerUnit
        return [
            (unit == .metric ? "500 m" : "½ \(unit.symbol)", per / 2),
            ("1 \(unit.symbol)", per),
            ("3 \(unit.symbol)", per * 3),
            ("5 \(unit.symbol)", per * 5),
        ]
    }

    private func addCustomDistance() {
        let text = newDistance.trimmingCharacters(in: .whitespaces)
        guard let entered = Double(text) else {
            distanceProblem = "Enter a number."
            return
        }
        add(metres: entered * settings.units.distance.metresPerUnit)
    }

    private func add(metres: Double) {
        // Bounds explained rather than enforced in silence. Below 50 m a "best
        // speed over" window is one or two GPS fixes and measures noise; above
        // 100 km no session is long enough for it to ever be reached.
        guard metres >= 50 else {
            distanceProblem = "Too short to measure — 50 m is the minimum."
            return
        }
        guard metres <= 100_000 else {
            distanceProblem = "Too long — 100 km is the maximum."
            return
        }
        let rounded = (metres * 10).rounded() / 10
        guard !settings.customDistances.contains(rounded) else {
            distanceProblem = "\(SpeedCategory.distance(metres: rounded).shortName) is already in the list."
            return
        }

        settings.customDistances.append(rounded)
        newDistance = ""
        distanceProblem = nil
        distanceFieldFocused = false
        withAnimation { justAdded = rounded }
    }

    private func exportAll() {
        do {
            // A backup of your own data keeps everything; the privacy trimming
            // is for what you send to other people.
            let data = try library.exportAll(privacy: .none)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openWater-backup.openwater")
            try data.write(to: url, options: .atomic)
            exportURL = url
            isExporting = true
        } catch {
            exportURL = nil
        }
    }
}
