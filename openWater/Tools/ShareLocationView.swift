import MapKit
import OpenWaterCore
import SwiftUI

/// Send a pin of where you are standing.
///
/// The downwind problem this exists for: the run ends where the wind says it
/// ends, and somebody with a car needs to find you on a stretch of shoreline
/// with no address. One tap shares links that open in the maps app the driver
/// already uses — plus the raw coordinates, because a lat/long still works
/// when someone's phone has one bar and no data.
///
/// GPS runs only while this screen is open — the same foreground-only warm-up
/// the Record tab uses — and the position leaves the phone only when the
/// rider taps a share button. Nothing here is passive.
struct ShareLocationView: View {

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(\.openURL) private var openURL
    /// Remembered, because which maps app your people use does not change
    /// between pins.
    @AppStorage("tools.mapProvider") private var providerID = ToolKit.MapProvider.google.rawValue

    private var provider: ToolKit.MapProvider {
        ToolKit.MapProvider(rawValue: providerID) ?? .apple
    }

    private var coordinate: Geo.Coordinate? { recorder.location.lastCoordinate }
    private var accuracy: Double { recorder.location.latestAccuracy }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                mapCard

                if let coordinate {
                    VStack(spacing: 4) {
                        Text(coordinateText(coordinate))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        if accuracy >= 0 {
                            Text("accurate to ±\(Int(accuracy.rounded())) m")
                                .font(.caption)
                                .foregroundStyle(accuracy <= 15 ? .secondary : Color.orange)
                        }
                    }

                    shareButtons(coordinate)
                } else {
                    waitingState
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Share My Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
    }

    // MARK: - Pieces

    private var mapCard: some View {
        Group {
            if let coordinate {
                Map(position: .constant(.region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )))) {
                    UserAnnotation()
                    Marker("You", coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
                .allowsHitTesting(false)
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    Image(systemName: "location.viewfinder")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func shareButtons(_ coordinate: Geo.Coordinate) -> some View {
        let url = provider.url(for: coordinate)
        return VStack(spacing: 10) {
            Picker("Maps app", selection: $providerID) {
                ForEach(ToolKit.MapProvider.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)

            // The system sheet is the headline action: it reaches every app on
            // the phone, WhatsApp and Messages included, and it is where
            // people expect sharing to live. A URL rather than a sentence, so
            // what lands in the thread is a tappable link with a map preview
            // instead of a paragraph somebody has to read.
            ShareLink(item: url) {
                Label("Share Pin", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            }

            // Direct lines for the two apps shuttle logistics actually happen
            // in, for anyone who finds the sheet a step too many with wet
            // hands.
            QuickShareButtons(message: url.absoluteString)
        }
    }

    private var waitingState: some View {
        VStack(spacing: 8) {
            if recorder.location.authorization == .denied {
                Label("Location access is off", systemImage: "location.slash")
                    .font(.subheadline.weight(.medium))
                Text("Turn it on in Settings to share where you are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Finding you…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Payload

    private func coordinateText(_ c: Geo.Coordinate) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }
}

/// The same screen, presented rather than pushed.
///
/// Sharing a pin is not only a Tools errand. The moment it is wanted most —
/// standing on a beach at the end of a run, telling a driver where to come —
/// is the moment the Spots map is already open, and walking to another tab to
/// do it is a detour. Presenting the same view rather than copying it keeps
/// one implementation of the pin, the maps-app choice and the share sheet.
struct ShareLocationSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShareLocationView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // Full height, not medium. Half a sheet cut the quick-share row in
        // two, and those buttons are the whole point for anyone doing this
        // with cold hands at the end of a run — nothing here should need a
        // scroll to find.
        .presentationDetents([.large])
    }
}
