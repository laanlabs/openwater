import MapKit
import OpenWaterCore
import SwiftUI

/// One buoy, in full.
///
/// The list can only afford a line each, which is enough to compare them and
/// not enough to decide whether to trust one. This says what it is
/// measuring, when it last said so, and — the part the list cannot show —
/// where it is moored. A buoy twelve kilometres away is a different reading
/// depending on whether it sits outside the bar or inside the bay.
struct BuoyDetailScreen: View {

    let buoy: Buoy
    let from: Geo.Coordinate

    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    private var units: UnitPreferences { settings.units }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                map
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let reading = buoy.reading {
                    if let direction = reading.meanDirectionDeg {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                // Pointing the way the waves travel, which is
                                // how an arrow on a swell chart is read.
                                .rotationEffect(.degrees(direction + 180))
                                .foregroundStyle(.teal)
                            Text("Waves from \(Format.cardinal(direction))")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 10) {
                        tile("Wave height", reading.waveHeightM.map {
                            Format.height($0, unit: units.distance)
                        })
                        tile("Dominant period", reading.dominantPeriodS.map {
                            "\(Int($0.rounded())) s"
                        })
                        tile("Mean direction", reading.meanDirectionDeg.map {
                            "\(Format.cardinal($0)) \(Int($0.rounded()))°"
                        })
                        tile("Water", reading.waterTempC.map {
                            Format.temperature($0, unit: units.temperatureUnit)
                        })
                        tile("Wind", reading.windKn.map {
                            Format.speed($0 / 1.94384, unit: units.speed, decimals: 0)
                        })
                    }

                    if let at = reading.at {
                        Text("Measured \(at.formatted(.relative(presentation: .named)))"
                             + " · \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("This station is listed but not reporting. NDBC sensors go down "
                         + "often enough that a silent buoy is normal rather than alarming.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    openURL(buoy.url)
                } label: {
                    Label("Open on NDBC", systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.semibold))
                }

                Text("Station \(buoy.id) · \(Format.distance(buoy.metres, unit: units.distance)) away. "
                     + "Measured on the water by NOAA's National Data Buoy Center, not modelled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(buoy.name)
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Buoy detail")
    }

    private var map: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: buoy.coordinate.clCoordinate,
            latitudinalMeters: max(4_000, buoy.metres * 2.6),
            longitudinalMeters: max(4_000, buoy.metres * 2.6)
        ))) {
            Annotation(buoy.name, coordinate: buoy.coordinate.clCoordinate) {
                BuoyPin()
            }
            Annotation("Here", coordinate: from.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func tile(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every nearby buoy at once.
///
/// Distances in a list are a poor way to choose between buoys, because the
/// nearest one is often on the wrong side of a headland. Seen on a map the
/// choice makes itself.
struct BuoyMapScreen: View {

    let buoys: [Buoy]
    let from: Geo.Coordinate

    @Environment(AppSettings.self) private var settings
    @State private var chosen: Buoy?

    var body: some View {
        Map {
            Annotation("Here", coordinate: from.clCoordinate) {
                Circle()
                    .fill(.tint)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            ForEach(buoys) { buoy in
                Annotation(buoy.name, coordinate: buoy.coordinate.clCoordinate) {
                    Button { chosen = buoy } label: {
                        BuoyPin(waveHeightM: buoy.reading?.waveHeightM,
                                unit: settings.units.distance)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .navigationTitle("Buoys nearby")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Buoys nearby")
        .sheet(item: $chosen) { buoy in
            NavigationStack {
                BuoyDetailScreen(buoy: buoy, from: from)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// A buoy, with its wave height on it when it has one.
struct BuoyPin: View {
    var waveHeightM: Double?
    var unit: DistanceUnit = .metric

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "water.waves")
                    .font(.system(size: 10, weight: .bold))
                if let waveHeightM {
                    Text(Format.height(waveHeightM, unit: unit))
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
    }
}
