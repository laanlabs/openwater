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
        VStack(spacing: 10) {
            // The system sheet is the headline action: it reaches every app on
            // the phone, WhatsApp and Messages included, and it is where
            // people expect sharing to live.
            ShareLink(item: message(coordinate)) {
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
            QuickShareButtons(message: message(coordinate))
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

    /// The message a shuttle driver can actually use: a link for whichever
    /// maps app they have, and the raw numbers for when they have neither.
    private func message(_ c: Geo.Coordinate) -> String {
        var text = "My location: " + ToolKit.mapsLinks(for: c)
        if accuracy >= 0 { text += " (±\(Int(accuracy.rounded())) m)" }
        return text
    }
}
