import MapKit
import OpenWaterCore
import SwiftUI

/// The waves a rider caught, measured against the swell they set.
///
/// Anchored on the swell arrow and deliberately not the wind — a wave day is
/// exactly the day the two disagree, a side-shore breeze over a groundswell,
/// and every wind-anchored screen calls that riding across. See
/// `WaveRideFinder` for the rules. Nothing here touches how runs, legs or
/// glides are worked out; this is another reading of the same track.
struct WaveDetailView: View {

    let session: Session
    let summary: SessionSummary
    var onSetWind: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    @State private var waves: WaveRideSummary?
    @State private var selectedRide: Int?

    /// How the rows are stacked. Time order is the default because the list
    /// reads like the session; the other two answer "which was my best wave"
    /// without scanning seventy-eight rows. A ride keeps its number whatever
    /// the order — the number is its badge on the map, not its rank.
    private enum Order: String, CaseIterable, Identifiable {
        case time = "In order"
        case longest = "Longest"
        case fastest = "Fastest"
        var id: String { rawValue }
    }

    @State private var order: Order = .time

    private func ordered(_ waves: WaveRideSummary) -> [WaveRide] {
        switch order {
        case .time: waves.rides
        case .longest: waves.rides.sorted { $0.duration > $1.duration }
        case .fastest: waves.rides.sorted { $0.peakSpeed > $1.peakSpeed }
        }
    }

    private var units: UnitPreferences { settings.units }

    private var thresholds: SportThresholds {
        settings.thresholds(for: session.sport)
    }

    /// The swell's colour everywhere in the app, so the arrow on the
    /// conditions dial and the rides on this map read as one thing.
    private static let waveColour = Color.teal

    /// A height under five centimetres is the slider never having moved.
    private var missingHeight: Bool { (session.swellHeight ?? 0) <= 0.05 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session.swellDirection == nil {
                    needsSwellCard
                } else if let waves, waves.count > 0 {
                    if missingHeight { needsHeightCard }
                    summaryCard(waves)
                    mapCard(waves)
                    ridesCard(waves)
                } else if waves != nil {
                    if missingHeight { needsHeightCard }
                    nothingFound
                }

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wave Rides")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Session · Waves")
        .task(id: session.swellDirection) {
            guard let swellFrom = session.swellDirection else {
                waves = nil
                return
            }
            waves = WaveRideFinder(thresholds: thresholds)
                .rides(in: session.track, flights: summary.flights, swellFrom: swellFrom)
        }
    }

    // MARK: - Nothing to measure from

    /// The one thing this screen cannot do without, asked for with the same
    /// card-and-button shape the Runs tab uses for a missing wind.
    private var needsSwellCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Which way were the waves going?", systemImage: "water.waves")
                .font(.subheadline.weight(.semibold))
            Text("Wave rides are measured against the swell — deliberately "
                 + "not the wind, because on a wave day the two often disagree. "
                 + "Point the swell arrow, set its height while you're there, "
                 + "and this screen fills in. \"Look up that day's conditions\" "
                 + "can fetch both for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSetWind) {
                Text("Set the swell")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Self.waveColour, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardChrome()
    }

    /// The direction is enough to *find* the rides, so nothing is withheld —
    /// but a wave day without a size is half a story, and this is the screen
    /// where the rider is thinking about the waves. Asked here, loudly,
    /// rather than silently tolerated.
    private var needsHeightCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How big was it?", systemImage: "water.waves")
                .font(.subheadline.weight(.semibold))
            Text("The swell height isn't set. The rides below are found from "
                 + "the swell's direction alone — add the height so the day "
                 + "reads whole, or let the lookup fetch it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSetWind) {
                Text("Set the swell height")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Self.waveColour, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .cardChrome()
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No wave rides found")
                .font(.subheadline.weight(.semibold))
            Text("Nothing accelerated while pointed the way the swell was "
                 + "travelling. If that reads wrong, check the swell arrow — "
                 + "every ride here is measured against it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check the swell direction", action: onSetWind)
                .font(.caption.weight(.semibold))
        }
        .padding(14)
        .cardChrome()
    }

    // MARK: - Summary

    private func summaryCard(_ waves: WaveRideSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(waves.count == 1 ? "1 wave" : "\(waves.count) waves")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 8)
                Text("\(Format.distance(waves.distance, unit: units.distance)) · \(Format.shortDuration(waves.timeOnWaves)) riding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 18) {
                measure("Longest", Format.shortDuration(waves.longest?.duration ?? 0))
                measure("Fastest", Format.speed(waves.fastest?.peakSpeed ?? 0,
                                                unit: units.speed, decimals: 1))
                measure("Typical", Format.shortDuration(waves.averageDuration))
            }
        }
        .padding(14)
        .cardChrome()
    }

    private func measure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: - Map

    private func mapCard(_ waves: WaveRideSummary) -> some View {
        Map {
            MapPolyline(coordinates: session.track.points.map(\.clCoordinate))
                .stroke(.gray.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // The others first, the chosen one last — same as every map that
            // draws runs, and for the same reason.
            ForEach(waves.rides.filter { $0.id != selectedRide }) { ride in
                MapPolyline(coordinates: coordinates(of: ride))
                    .stroke(selectedRide == nil ? Self.waveColour
                            : Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(waves.rides.filter { $0.id == selectedRide }) { ride in
                MapPolyline(coordinates: coordinates(of: ride))
                    .stroke(Self.waveColour,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            // The chosen ride wears an arrow at its kick-out, pointed the way
            // the ride made ground — so "which way was I going" is answered
            // by looking, not by trusting.
            ForEach(waves.rides.filter { $0.id == selectedRide }) { ride in
                Annotation("", coordinate: endpoint(of: ride), anchor: .center) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(ride.netBearing))
                        .frame(width: 22, height: 22)
                        .background(Self.waveColour, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .annotationTitles(.hidden)
            }

            // Once one is chosen, only its own badge stays.
            ForEach(waves.rides.filter { selectedRide == nil || $0.id == selectedRide }) { ride in
                Annotation("", coordinate: midpoint(of: ride), anchor: .center) {
                    Button {
                        withAnimation(.snappy) {
                            selectedRide = selectedRide == ride.id ? nil : ride.id
                        }
                    } label: {
                        Text("\(ride.id + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: selectedRide == ride.id ? 24 : 18,
                                   height: selectedRide == ride.id ? 24 : 18)
                            .background(Self.waveColour, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomLeading) {
            if selectedRide != nil {
                Button("Show all") {
                    withAnimation(.snappy) { selectedRide = nil }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
    }

    private func coordinates(of ride: WaveRide) -> [CLLocationCoordinate2D] {
        guard ride.startIndex <= ride.endIndex,
              ride.endIndex < session.track.points.count else { return [] }
        return session.track.points[ride.startIndex...ride.endIndex].map(\.clCoordinate)
    }

    private func midpoint(of ride: WaveRide) -> CLLocationCoordinate2D {
        session.track.points[min(ride.midIndex, session.track.points.count - 1)].clCoordinate
    }

    private func endpoint(of ride: WaveRide) -> CLLocationCoordinate2D {
        session.track.points[min(ride.endIndex, session.track.points.count - 1)].clCoordinate
    }

    // MARK: - The rides

    private func ridesCard(_ waves: WaveRideSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Order", selection: $order) {
                ForEach(Order.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 8)

            ForEach(ordered(waves)) { ride in
                Button {
                    withAnimation(.snappy) {
                        selectedRide = selectedRide == ride.id ? nil : ride.id
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("\(ride.id + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(selectedRide == nil || selectedRide == ride.id
                                        ? Self.waveColour
                                        : Color.secondary.opacity(0.35), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Format.distance(ride.distance, unit: units.distance)) · \(Format.shortDuration(ride.duration))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("\(Format.speed(ride.averageSpeed, unit: units.speed, decimals: 1)) avg · \(Format.speed(ride.peakSpeed, unit: units.speed, decimals: 1)) peak")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer(minLength: 8)

                        // How square to the swell it was ridden: small is
                        // straight down the face, forty is down the line.
                        Text("\(Int(ride.offSwell.rounded()))° off")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(ride.offSwell <= 30 ? .green : .secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(selectedRide == ride.id
                                ? AnyShapeStyle(Self.waveColour.opacity(0.12))
                                : AnyShapeStyle(.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .cardChrome()
    }

    // MARK: - Footer

    /// How the rides are found, said plainly — and where the anchor is, so a
    /// wrong swell arrow gets corrected instead of distrusted.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let swellFrom = session.swellDirection {
                Text("Measured against swell from \(Format.cardinal(swellFrom)) \(Int(swellFrom.rounded()))°"
                     + (session.swellHeight.map { $0 > 0.05 ? " · \(Format.height($0, unit: units.distance))" : "" } ?? "")
                     + ", as you set it.")
                    .font(.caption.weight(.medium))
            }
            Text("A wave ride is a stretch on the foil, at or above your own "
                 + "pace for the day, where the speed *rose* while you pointed "
                 + "within \(Int(WaveRideFinder.halfAngle))° of the way the swell "
                 + "was travelling — and the whole ride, takeoff to kick-out, "
                 + "made ground that way. The wind is not consulted: waves keep "
                 + "their own direction. Runs and glides are unchanged by any "
                 + "of this. Tap a ride for the arrow showing which way it went.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Adjust the swell", action: onSetWind)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
