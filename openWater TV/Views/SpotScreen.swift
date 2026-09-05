import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// One spot, in full: what it is doing now and what it does next.
///
/// The phone's conditions sheet has five tabs and thirty sections. This has
/// three blocks, because a television is read, not browsed — the number, the
/// day ahead, and whether a camera can show you the water.
/// A starred spot, reported in full.
///
/// This was a thinner screen of its own — the wind now, twelve hours, the
/// measured stations and the cameras — while a point picked on the map got
/// the rain chance, the long-range charts and the model picker. A saved spot
/// is if anything the place a rider cares *most* about, so it gets the same
/// report; `ConditionsScreen` takes the spot itself, and is told it came from
/// the board so it can offer the way back out to the map.
struct SpotScreen: View {

    let spot: GuideSpot

    var body: some View {
        ConditionsScreen(here: Geo.Coordinate(latitude: spot.latitude,
                                              longitude: spot.longitude),
                         placeName: spot.name,
                         spot: spot,
                         openedFromBoard: true)
    }
}

// MARK: - The day ahead

/// Twelve hours as bars, coloured by the map's own ramp.
///
/// Internal rather than private: the map's conditions screen shows the same
/// twelve hours for the point under its crosshairs, and two copies of a bar
/// chart is how the phone and the television start disagreeing about the
/// weather.
///
/// No axis and no scrubber. Somebody looking at a television wants the shape —
/// whether it builds through the morning or dies at four — and a shape needs
/// neither.
struct ForecastStrip: View {

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

/// Stations that are measuring, and only those. Shared with the map's
/// conditions screen for `ForecastStrip`'s reason.
struct MeasuredStations: View {

    let rows: [(FreeStation, StationObservation)]

    /// The mean, on its own, as a number.
    ///
    /// This used to be one crammed string — "10g12 kn", "2g6 kn" — which is
    /// a wind reading written as a serial number. The mean and the gust are
    /// two different facts and a rider reads them differently: the first
    /// decides whether to go, the second whether it will be pleasant. So
    /// they are two labels now, sized differently, with the word "gusting"
    /// spelled out rather than compressed to a g.
    static func mean(_ observation: StationObservation) -> String? {
        if let mean = observation.windKn { return "\(Int(mean.rounded()))" }
        // A gust with no mean is still a reading — the weather service writes
        // that "0G4" — so a station reporting only gusts shows a zero mean
        // rather than a dash, and the gust below carries the information.
        if observation.gustKn != nil { return "0" }
        return nil
    }

    static func gust(_ observation: StationObservation) -> String? {
        guard let gust = observation.gustKn else { return nil }
        return "gusting \(Int(gust.rounded()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MEASURED NEARBY")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            // A focus stop per row, not one for the whole list. Eight
            // stations is taller than a screen, and a single focusable block
            // taller than the viewport is the one thing a tvOS scroll view
            // cannot help with: it scrolls to show the block, and then there
            // is nowhere further for focus to go, so the rows past the bottom
            // stay past the bottom. Per row, Down walks the list.
            ForEach(rows, id: \.0.id) { station, observation in
                ScrollStop {
                    HStack(spacing: 24) {
                        Text(station.name)
                            .font(.system(size: 28))
                            .lineLimit(1)
                        Spacer()
                        // A gust with no mean is still a reading — the weather
                        // service writes that "0G4" — so the label follows what
                        // the instrument actually said.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let mean = Self.mean(observation) {
                                Text(mean)
                                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                Text("kn")
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("—")
                                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            if let gust = Self.gust(observation) {
                                Text(gust)
                                    .font(.system(size: 21))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(width: 260, alignment: .trailing)
                        if let at = observation.at {
                            Text(at, style: .relative)
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
