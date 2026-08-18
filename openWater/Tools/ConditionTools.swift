import Combine
import MapKit
import OpenWaterCore
import SwiftUI

// The Shuttle Planner lived here until 2026-08-18. Its question — how far
// is the run, and is today's wind actually pointing down it — is now
// answered by saved routes on the Spots map, which sample the whole line
// instead of three points and add the water. The Tools row survives as a
// door: it walks the old stored endpoints into a saved route once and
// opens it. The driver's share message lives on in the route panel.

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
                                // Shaped like the reading it becomes, so the
                                // row does not jump when the wind arrives.
                                LoadingPlaceholder(height: 20, width: 70)
                                    .padding(.top, 8)
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
        .feedbackButton("Wind Here")
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
        .feedbackButton("Daylight")
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
        .feedbackButton("Speedo")
        .toolLocation(recorder)
        // The whole point is glancing at it over minutes — the screen must
        // not sleep mid-tow. Restored on the way out.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
