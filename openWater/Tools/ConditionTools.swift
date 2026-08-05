import Combine
import MapKit
import OpenWaterCore
import SwiftUI

// MARK: - Shuttle Planner

/// The downwind question, answered before anyone drives: how far is the run,
/// and is today's wind actually pointing down it. A run 30° off the wind is a
/// different sport from a run dead down it, and the difference is exactly
/// what this screen puts a number on.
struct ShuttlePlannerView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings

    @State private var launch: GuideSpot?
    @State private var takeout: GuideSpot?
    @State private var picking: End?
    @State private var wind: WindReading?

    enum End: String, Identifiable {
        case launch = "Launch", takeout = "Takeout"
        var id: String { rawValue }
    }

    private var launchCoordinate: Geo.Coordinate? {
        launch.map { Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            ?? recorder.location.lastCoordinate
    }

    private var takeoutCoordinate: Geo.Coordinate? {
        takeout.map { Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                plannerMap
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 0) {
                    pickerRow(.launch, name: launch?.name ?? "Current location")
                    Divider().padding(.leading, 14)
                    pickerRow(.takeout, name: takeout?.name ?? "Choose…")
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                if let from = launchCoordinate, let to = takeoutCoordinate {
                    runCard(from: from, to: to)
                    shareButton(from: from, to: to)
                } else {
                    Text("Pick a takeout to see the run.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Shuttle Planner")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        .task { await guide.load() }
        .task(id: "\(launch?.spotId ?? "here")-\(takeout?.spotId ?? "")") {
            guard let from = launchCoordinate, let to = takeoutCoordinate else { return }
            let mid = Geo.Coordinate(latitude: (from.latitude + to.latitude) / 2,
                                     longitude: (from.longitude + to.longitude) / 2)
            wind = await guide.currentWind(at: mid)
        }
        .sheet(item: $picking) { end in
            SpotPickerSheet(
                title: "\(end.rawValue) spot",
                near: launchCoordinate ?? recorder.location.lastCoordinate,
                allowCurrentLocation: end == .launch
            ) { choice in
                switch end {
                case .launch: launch = choice
                case .takeout: takeout = choice
                }
                picking = nil
            }
        }
    }

    private func pickerRow(_ end: End, name: String) -> some View {
        Button { picking = end } label: {
            HStack {
                Text(end.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var plannerMap: some View {
        let from = launchCoordinate
        let to = takeoutCoordinate
        Map(initialPosition: .automatic) {
            if let from {
                Marker("Launch", systemImage: "flag",
                       coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude))
            }
            if let to {
                Marker("Takeout", systemImage: "flag.checkered",
                       coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude))
            }
            if let from, let to {
                MapPolyline(coordinates: [
                    CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
                    CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude),
                ])
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
            }
        }
        .allowsHitTesting(false)
        .id("\(launch?.spotId ?? "here")-\(takeout?.spotId ?? "")")
    }

    private func runCard(from: Geo.Coordinate, to: Geo.Coordinate) -> some View {
        let metres = Geo.distance(from, to)
        let bearing = Geo.bearing(from: from, to: to)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                tile("Run", Format.distance(metres, unit: settings.units.distance))
                tile("Bearing", "\(Int(bearing.rounded()))°")
                if let wind {
                    tile("Wind", "\(Int(wind.speedKn.rounded()))kn \(wind.cardinal)")
                }
            }
            if let wind {
                let off = Solar.runAlignment(bearing: bearing, windFrom: wind.directionDeg)
                Label(
                    off < 1 ? "Dead downwind" : "\(Int(off.rounded()))° off dead downwind",
                    systemImage: off <= 15 ? "checkmark.circle.fill"
                        : off <= 30 ? "exclamationmark.triangle" : "xmark.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(off <= 15 ? Color.green : off <= 30 ? .orange : .red)
                Text("Model wind at the midpoint of the run — check a meter before committing a shuttle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shareButton(from: Geo.Coordinate, to: Geo.Coordinate) -> some View {
        let metres = Geo.distance(from, to)
        let message = "Downwind run: \(launch?.name ?? "launch") → \(takeout?.name ?? "takeout"), "
            + "\(Format.distance(metres, unit: settings.units.distance)). "
            + "Launch: \(ToolKit.mapsLinks(for: from, label: "Launch")) "
            + "Takeout: \(ToolKit.mapsLinks(for: to, label: "Takeout"))"
        return VStack(spacing: 10) {
            ShareLink(item: message) {
                Label("Share Shuttle Plan", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            }
            QuickShareButtons(message: message)
        }
    }
}

/// Choose a spot from the guide, nearest first.
struct SpotPickerSheet: View {
    let title: String
    let near: Geo.Coordinate?
    var allowCurrentLocation = false
    let onPick: (GuideSpot?) -> Void

    @Environment(SpotGuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [GuideSpot] {
        var list = guide.spots
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if let near {
            list.sort {
                Geo.distance(near, .init(latitude: $0.latitude, longitude: $0.longitude)) <
                Geo.distance(near, .init(latitude: $1.latitude, longitude: $1.longitude))
            }
        }
        return Array(list.prefix(40))
    }

    var body: some View {
        NavigationStack {
            List {
                if allowCurrentLocation {
                    Button {
                        onPick(nil)
                    } label: {
                        Label("Current location", systemImage: "location.fill")
                    }
                }
                ForEach(candidates) { spot in
                    Button {
                        onPick(spot)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spot.name)
                                .foregroundStyle(.primary)
                            Text(spot.where_)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Wind Here

/// The spot page's wind card, pointed at your feet. For the launch that is
/// not in any guide — which is most launches.
struct WindHereView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder

    @State private var reading: WindReading?
    @State private var forecast: [WindForecastHour] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reading == nil ? "WIND" : "WIND · MODEL ESTIMATE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            if let reading {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(Int(reading.speedKn.rounded()))")
                                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                                        .foregroundStyle(reading.isFiring ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                    Text("kn \(reading.cardinal)\(reading.gustKn.map { " · gusts \(Int($0.rounded()))" } ?? "")")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ProgressView().padding(.top, 8)
                            }
                        }
                        Spacer()
                        if let reading {
                            Image(systemName: "arrow.down")
                                .font(.title2.weight(.semibold))
                                .rotationEffect(.degrees(reading.directionDeg))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !forecast.isEmpty {
                        WindForecastBars(forecast: forecast)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                Text("A model on a roughly 2 km grid, not an anemometer — the same source and the same honesty as the spot pages. For a real meter, favorite a spot with one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wind Here")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        .task(id: "\(recorder.location.lastCoordinate != nil)") {
            guard let here = recorder.location.lastCoordinate else { return }
            reading = await guide.currentWind(at: here)
            forecast = await guide.forecast(latitude: here.latitude, longitude: here.longitude)
        }
    }
}

// MARK: - Daylight

/// "Do I have time?" — sunset, last usable light, and the countdown, computed
/// on the phone so it works on a beach with no signal.
struct DaylightView: View {

    @Environment(PhoneRecorder.self) private var recorder

    /// Ticks once a minute so the countdown stays honest while you stare at it.
    @State private var now = Date()

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var day: Solar.Day? {
        guard let here = recorder.location.lastCoordinate else { return nil }
        return Solar.day(latitude: here.latitude, longitude: here.longitude, on: now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let day {
                    if let dusk = day.civilDusk, dusk > now {
                        VStack(spacing: 2) {
                            Text("USABLE LIGHT LEFT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(Format.duration(dusk.timeIntervalSince(now)))
                                .font(.system(size: 44, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(spacing: 0) {
                        row("Golden hour", day.goldenHourStart, symbol: "sun.max")
                        Divider().padding(.leading, 46)
                        row("Sunset", day.sunset, symbol: "sunset")
                        Divider().padding(.leading, 46)
                        row("Last usable light", day.civilDusk, symbol: "moon.haze")
                        Divider().padding(.leading, 46)
                        row("Sunrise tomorrow",
                            Solar.day(latitude: recorder.location.lastCoordinate?.latitude ?? 0,
                                      longitude: recorder.location.lastCoordinate?.longitude ?? 0,
                                      on: now.addingTimeInterval(86400)).sunrise,
                            symbol: "sunrise")
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    Text("Last usable light is civil dusk — the sun six degrees below the horizon. After that you are riding on faith and other people's nav lights.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    Text("Waiting for a location fix…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Daylight")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        .onReceive(clock) { now = $0 }
    }

    private func row(_ label: String, _ date: Date?, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(date?.formatted(date: .omitted, time: .shortened) ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

// MARK: - Big Speedo

/// A speedometer and nothing else. For tow tuning, ferry rides, and settling
/// arguments — no recording, no session, just the number, big enough to read
/// from the other end of the boat.
struct BigSpeedoView: View {

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings

    private var speed: Double { recorder.location.lastSpeed }
    private var accuracy: Double { recorder.location.latestAccuracy }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(speed >= 0
                 ? Format.speed(speed, unit: settings.units.speed, decimals: 1, includeSymbol: false)
                 : "—")
                .font(.system(size: 120, weight: .black, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(speed * 10))
            Text(settings.units.speed.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if accuracy >= 0 {
                Text("GPS ±\(Int(accuracy.rounded())) m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Speedo")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        // The whole point is glancing at it over minutes — the screen must
        // not sleep mid-tow. Restored on the way out.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
