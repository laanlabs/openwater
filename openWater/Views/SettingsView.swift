import OpenWaterCore
import SwiftData
import SwiftUI

struct SettingsView: View {

    @Environment(SessionLibrary.self) private var library
    @Environment(PhoneSyncClient.self) private var sync
    @Environment(AppSettings.self) private var settings

    @State private var newDistance = ""
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var recomputeMessage: String?

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Units") {
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

                Section("Apple Watch") {
                    WatchStatusView()
                }

                Section {
                    Button("Export all sessions") { exportAll() }
                    if !library.staleSessions().isEmpty {
                        Button("Recompute \(library.staleSessions().count) session(s)") {
                            Task {
                                let count = await library.recomputeStaleSessions()
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
            .navigationTitle("Settings")
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
    private var customWindowsSection: some View {
        @Bindable var settings = settings

        return Section {
            ForEach(settings.customDistances.sorted(), id: \.self) { metres in
                HStack {
                    Text(SpeedCategory.distance(metres: metres).shortName)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        settings.customDistances.removeAll { $0 == metres }
                    }
                    .font(.caption)
                }
            }
            HStack {
                TextField("Distance in metres", text: $newDistance)
                    .keyboardType(.numberPad)
                Button("Add") {
                    if let metres = Double(newDistance), metres >= 50, metres <= 100_000 {
                        settings.customDistances.append(metres)
                        settings.customDistances = Array(Set(settings.customDistances))
                    }
                    newDistance = ""
                }
                .disabled(Double(newDistance) == nil)
            }
        } header: {
            Text("Custom distances")
        } footer: {
            Text("Add any distance you want a best time over — 1 km, 3 km, 5 km. Adding one recalculates from your stored tracks, so it applies to every session you already have.")
        }
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
