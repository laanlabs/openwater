import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// One spot, in full: what it is doing now and what it does next.
///
/// The phone's conditions sheet has five tabs and thirty sections. This has
/// three blocks, because a television is read, not browsed — the number, the
/// day ahead, and whether a camera can show you the water.
struct SpotScreen: View {

    let spot: GuideSpot

    @Environment(SpotGuideStore.self) private var guide

    @State private var ahead: [WindForecastHour] = []
    @State private var cams: [SpotGuideStore.GuideResource] = []
    @State private var stations: [FreeStation] = []
    @State private var measured: [String: StationObservation] = [:]

    private var reading: WindReading? { guide.wind[spot.spotId] }

    private var here: Geo.Coordinate {
        Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header
                if !ahead.isEmpty { ForecastStrip(hours: ahead) }
                if !reportingStations.isEmpty { MeasuredStations(rows: reportingStations) }
                if !cams.isEmpty { SpotCams(cams: cams, spotName: spot.name) }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .task {
            async let forecast = guide.forecast(for: spot)
            async let nearby = guide.nearbyResources(to: spot, radius: 60_000)
            async let free = FreeStations.near(here, limit: 8, radius: 40_000)
            ahead = await forecast
            cams = await nearby.filter { $0.kind == .camera && $0.playback != nil }
            stations = await free

            // Readings come after the list, the way the phone's sheet does it:
            // each one is its own request, and the names are useful before the
            // numbers land.
            await withTaskGroup(of: (String, StationObservation?).self) { group in
                for station in stations {
                    group.addTask { (station.id, await FreeStations.latest(for: station)) }
                }
                for await (id, observation) in group {
                    if let observation { measured[id] = observation }
                }
            }
        }
    }

    /// Only stations that actually answered, with a reading recent enough to
    /// mean anything — the map rules' first and loudest one. A number on a
    /// television is read from further away than a number on a phone, and
    /// there is no tapping it to find out where it came from.
    private var reportingStations: [(FreeStation, StationObservation)] {
        stations.compactMap { station in
            guard let observation = measured[station.id],
                  observation.reports, !observation.isStale
            else { return nil }
            return (station, observation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spot.name)
                .font(.system(size: 62, weight: .bold))
            if let reading {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 40))
                        .rotationEffect(.degrees(reading.directionDeg + 180))
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.system(size: 130, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("kn \(reading.cardinal)")
                            .font(.system(size: 34, weight: .semibold))
                        if let gust = reading.gustKn {
                            Text("gusting \(Int(gust.rounded()))")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(reading.isFiring ? Color.accentColor : .primary)
                // Said plainly, once, the way the phone's card says it: this
                // is a model, and the measured numbers are further down.
                Text("Forecast model, not an anemometer.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The day ahead

/// Twelve hours as bars, coloured by the map's own ramp.
///
/// No axis and no scrubber. Somebody looking at a television wants the shape —
/// whether it builds through the morning or dies at four — and a shape needs
/// neither.
private struct ForecastStrip: View {

    let hours: [WindForecastHour]

    private var peak: Double { max(hours.map(\.speedKn).max() ?? 1, 15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NEXT TWELVE HOURS")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(hours) { hour in
                    VStack(spacing: 10) {
                        Text("\(Int(hour.speedKn.rounded()))")
                            .font(.system(size: 24, weight: .semibold))
                            .monospacedDigit()
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(WindPalette.smooth(for: hour.speedKn)))
                            .frame(height: max(8, 220 * hour.speedKn / peak))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 18))
                            .rotationEffect(.degrees(hour.directionDeg))
                            .foregroundStyle(.secondary)
                        Text(hour.date, format: .dateTime.hour())
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Actual instruments

/// Stations that are measuring, and only those.
private struct MeasuredStations: View {

    let rows: [(FreeStation, StationObservation)]

    static func wind(_ observation: StationObservation) -> String {
        if let mean = observation.windKn, let gust = observation.gustKn {
            return "\(Int(mean.rounded())) g\(Int(gust.rounded())) kn"
        }
        if let mean = observation.windKn { return "\(Int(mean.rounded())) kn" }
        if let gust = observation.gustKn { return "gusting \(Int(gust.rounded())) kn" }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MEASURED NEARBY")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0.id) { station, observation in
                HStack(spacing: 24) {
                    Text(station.name)
                        .font(.system(size: 28))
                        .lineLimit(1)
                    Spacer()
                    // A gust with no mean is still a reading — the weather
                    // service writes that "0G4" — so the label follows what
                    // the instrument actually said.
                    Text(Self.wind(observation))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                    if let at = observation.at {
                        Text(at, style: .relative)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .frame(width: 200, alignment: .trailing)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Cams at this spot

private struct SpotCams: View {

    let cams: [SpotGuideStore.GuideResource]
    let spotName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CAMERAS")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 28) {
                    ForEach(cams) { cam in
                        CamCard(cam: cam)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}
