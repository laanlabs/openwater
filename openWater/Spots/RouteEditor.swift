import MapKit
import OpenWaterCore
import SwiftUI

// MARK: - Mode

/// What the Spots map is doing about routes, when it is doing anything.
///
/// Nil is today's map, untouched. Editing owns the map's taps; inspecting
/// owns the panel. The two never overlap, and leaving either restores the
/// map exactly as it was — the whole feature is strictly additive.
enum RouteMode: Equatable {
    /// Waypoints being laid down; `routeId` is set when re-editing a saved
    /// route's line rather than drawing a new one.
    case editing(draft: [Geo.Coordinate], routeId: UUID?)
    case inspecting(PlannedRoute)

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    var waypoints: [Geo.Coordinate] {
        switch self {
        case .editing(let draft, _): draft
        case .inspecting(let route): route.waypoints
        }
    }
}

// MARK: - Edit chrome

/// The strip that replaces the floating controls while a route is drawn:
/// what to do next, and the two ways out.
struct RouteEditChrome: View {

    let draftCount: Int
    let onUndo: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    private var instruction: String {
        switch draftCount {
        case 0: "Tap the map to set the start"
        case 1: "Tap to set the finish"
        default: "Tap to extend the route — drag a handle to adjust"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(instruction)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 7, y: 2)

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(.regularMaterial, in: Capsule())

                if draftCount > 0 {
                    Button {
                        onUndo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Remove last point")
                }

                Spacer()

                Button(action: onSave) {
                    Text("Save route")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(draftCount >= 2 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                                    in: Capsule())
                }
                .disabled(draftCount < 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// A draggable waypoint: ends are solid, midpoints hollow. The generous
/// frame is the touch target; the visible dot stays small so the line
/// stays readable.
struct RouteHandle: View {
    var isEnd = false

    var body: some View {
        Circle()
            .fill(isEnd ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemBackground)))
            .stroke(isEnd ? Color.white : Color.accentColor, lineWidth: 2.5)
            .frame(width: isEnd ? 18 : 14, height: isEnd ? 18 : 14)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
    }
}

// MARK: - Save sheet

/// Naming and expectations, once the line is drawn. Modeled on
/// `AddPrivateSpotSheet`: a confirmation map, a prefilled name that only
/// fills while the field is empty, and nothing else mandatory.
struct RouteSaveSheet: View {

    let draft: [Geo.Coordinate]
    /// Set when re-editing a saved route — keeps its name and settings.
    var editing: PlannedRoute?
    let onSave: (PlannedRoute) -> Void

    @Environment(RouteNamer.self) private var namer
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sport: Sport = .wingfoil
    @State private var speedKn: Double = PlannedRoute.cruiseKn(for: .wingfoil)
    @State private var suggested = false

    private var path: RoutePath { RoutePath(waypoints: draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(initialPosition: .region(region)) {
                        MapPolyline(coordinates: draft.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    .frame(height: 160)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("Name", text: $name)
                    Picker("Sport", selection: $sport) {
                        ForEach(Sport.allCases, id: \.self) { sport in
                            Text(sport.displayName).tag(sport)
                        }
                    }
                    Stepper(value: $speedKn, in: 4...30, step: 1) {
                        HStack {
                            Text("Expected speed")
                            Spacer()
                            Text("\(Int(speedKn)) kn")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("\(Format.distance(path.totalDistance, unit: .metric)) · about \(Format.duration(path.totalDistance / (speedKn * 0.5144))) at a steady \(Int(speedKn)) kn. The estimate along the route runs on this speed.")
                }
            }
            .navigationTitle(editing == nil ? "Save route" : "Edit route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        var route = editing ?? PlannedRoute(name: "Route", waypoints: draft)
                        route.name = trimmed.isEmpty ? route.name : trimmed
                        route.waypoints = draft
                        route.sport = sport
                        route.expectedSpeedKn = speedKn
                        onSave(route)
                        dismiss()
                    }
                    .disabled(draft.count < 2)
                }
            }
            .task {
                if let editing {
                    name = editing.name
                    sport = editing.sport ?? .wingfoil
                    speedKn = editing.speedKn
                    suggested = true
                }
                await suggestName()
            }
            .onChange(of: sport) { _, sport in
                // The stepper follows the sport until the rider moves it —
                // then their number stands.
                if editing == nil { speedKn = PlannedRoute.cruiseKn(for: sport) }
            }
        }
    }

    /// "Viento → Hatchery", spot-first then geocoder — the session namer's
    /// exact rule, and like the private-spot sheet it only fills an empty
    /// field.
    private func suggestName() async {
        guard !suggested, name.isEmpty,
              let start = draft.first, let end = draft.last else { return }
        suggested = true
        async let from = namer.name(for: start)
        async let to = namer.name(for: end)
        let (a, b) = await (from, to)
        guard name.isEmpty, let a, let b else { return }
        name = "\(a) → \(b)"
    }

    private var region: MKCoordinateRegion {
        boundingRegion(of: draft)
    }
}

/// A region that shows every waypoint with breathing room.
func boundingRegion(of coordinates: [Geo.Coordinate]) -> MKCoordinateRegion {
    guard let first = coordinates.first else {
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 90))
    }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for point in coordinates {
        minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
        minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
    }
    return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                       longitude: (minLon + maxLon) / 2),
        span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.5),
                               longitudeDelta: max(0.02, (maxLon - minLon) * 1.5))
    )
}

// MARK: - Route panel (inspect)

/// The panel under an inspected route: the run's facts, the shared hour
/// scrubber, and the estimate — where you'd be at the scrubbed instant and
/// what the wind is doing there. Scrubbing reads the in-memory grid; the
/// network was touched once, when the route opened.
struct RoutePanel: View {

    let route: PlannedRoute
    @Bindable var weather: RouteWeatherModel

    @Environment(AppSettings.self) private var settings
    @Environment(RouteStore.self) private var routeStore

    private var path: RoutePath { route.path }
    private var progress: RouteProgress { weather.progress(for: route) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                stat(Format.distance(path.totalDistance, unit: settings.units.distance), "distance")
                stat("\u{2248}\(Format.duration(path.totalDistance / (weather.speedKn * 0.5144)))",
                     "at \(Int(weather.speedKn)) kn")
                stat(shortTime(progress.eta), "arrives")
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Menu {
                    ForEach(departureChoices, id: \.self) { choice in
                        Button(shortTime(choice)) { weather.departure = choice }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.caption.weight(.semibold))
                        Text("Depart \(shortTime(weather.departure))")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)

                Stepper(value: $weather.speedKn, in: 4...30, step: 1) {
                    Text("\(Int(weather.speedKn)) kn")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .fixedSize()
                .onChange(of: weather.speedKn) { _, knots in
                    // The stepper is the route's memory, not a scratch pad.
                    var updated = route
                    updated.expectedSpeedKn = knots
                    routeStore.update(updated)
                }
            }

            if weather.isLoading, weather.grid == nil {
                LoadingPlaceholder(height: 120)
            } else if let grid = weather.grid, !grid.isEmpty {
                HourScrubber(hours: grid.hours, timeZone: .current, selection: $weather.scrub)

                markerReadout(grid: grid)
                sampleStrip(grid: grid)
                if let verdict = verdict(grid: grid) {
                    Text(verdict)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No wind forecast came back for this line.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Estimated position at a steady \(Int(weather.speedKn)) kn. Model forecast, not observation \u{2014} Open-Meteo (CC-BY 4.0).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .task(id: route.id) {
            await weather.load(for: route)
        }
    }

    /// Where the estimate stands at the scrubbed instant, and the wind
    /// interpolated to exactly there and then.
    private func markerReadout(grid: RouteForecastGrid) -> some View {
        let instant = weather.instant
        let metres = progress.distance(at: instant)
        let sample = grid.wind(atDistance: metres, time: instant)
        let bearing = path.bearing(atDistance: metres)
        let off: Double? = {
            guard let direction = sample?.directionDeg, let bearing else { return nil }
            return Solar.runAlignment(bearing: bearing, windFrom: direction)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.surfing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(positionCaption(metres: metres, instant: instant))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                if let sample {
                    HStack(spacing: 6) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 11, weight: .heavy))
                            .rotationEffect(.degrees(sample.directionDeg + 180))
                            .foregroundStyle(alignmentTint(off))
                        Text("\(Int(sample.speedKn.rounded())) kn")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    if let gust = sample.gustKn {
                        Text("g\(Int(gust.rounded()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let off {
                        Text("\(Int(off.rounded()))\u{00B0} off DW")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(alignmentTint(off))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(alignmentTint(off).opacity(0.14), in: Capsule())
                    }
                } else {
                    Text("No wind at this point.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let water = grid.current(atDistance: metres, time: instant), water.speedKn > 0.1 {
                currentRow(water, routeBearing: bearing)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The water under the estimate: how hard it runs, and whether it is
    /// carrying you or fighting you on this stretch. The arrow draws the
    /// set as-is — currents point toward, the one row where wind's +180
    /// habit would flip a river.
    private func currentRow(_ water: (speedKn: Double, setDeg: Double), routeBearing: Double?) -> some View {
        let relation: (label: String, tint: Color)? = routeBearing.map { bearing in
            let delta = abs(Geo.angleDelta(from: bearing, to: water.setDeg))
            if delta <= 60 { return ("with you", .green) }
            if delta >= 120 { return ("against you", .red) }
            return ("across", .orange)
        }
        return HStack(spacing: 8) {
            Image(systemName: "water.waves")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "location.north.fill")
                .font(.system(size: 10, weight: .heavy))
                .rotationEffect(.degrees(water.setDeg))
                .foregroundStyle(relation?.tint ?? .secondary)
            Text(String(format: "%.1f kn current", water.speedKn))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            if let relation {
                Text(relation.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(relation.tint)
            }
            if let height = grid_waveHeight {
                Text("· \(Format.height(height, unit: settings.units.distance)) waves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Wave height at the current marker, for the current row's tail.
    private var grid_waveHeight: Double? {
        guard let grid = weather.grid else { return nil }
        let metres = progress.distance(at: weather.instant)
        return grid.waveHeight(atDistance: metres, time: weather.instant)
    }

    /// Wind at every sample point for the scrubbed hour \u{2014} the shuttle
    /// planner's strip, generalized from three fixed labels to the line.
    private func sampleStrip(grid: RouteForecastGrid) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(grid.samples.indices, id: \.self) { index in
                    let sample = grid.samples[index]
                    let hour = grid.wind(atDistance: sample.distance, time: weather.instant)
                    let off = hour.map {
                        Solar.runAlignment(bearing: sample.legBearing, windFrom: $0.directionDeg)
                    }
                    VStack(spacing: 3) {
                        Text(label(for: index, of: grid.samples.count, metres: sample.distance))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if let hour {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 11, weight: .heavy))
                                .rotationEffect(.degrees(hour.directionDeg + 180))
                                .foregroundStyle(alignmentTint(off))
                            Text("\(Int(hour.speedKn.rounded()))")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        } else {
                            Text("\u{2014}").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 58)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    /// One sentence when the line disagrees with itself at the scrubbed
    /// hour.
    private func verdict(grid: RouteForecastGrid) -> String? {
        let offs = grid.samples.compactMap { sample -> Double? in
            grid.wind(atDistance: sample.distance, time: weather.instant).map {
                Solar.runAlignment(bearing: sample.legBearing, windFrom: $0.directionDeg)
            }
        }
        guard offs.count >= 3 else { return nil }
        let spread = (offs.max() ?? 0) - (offs.min() ?? 0)
        if spread > 25 {
            let worstIndex = offs.firstIndex(of: offs.max() ?? 0) ?? 0
            let fraction = Double(worstIndex) / Double(max(1, offs.count - 1))
            let where_ = fraction < 0.33 ? "start" : fraction < 0.66 ? "middle" : "last stretch"
            return "The wind bends along the line \u{2014} furthest off downwind in the \(where_)."
        }
        if (offs.max() ?? 0) <= 15 { return "Dead downwind the whole way." }
        return nil
    }

    // MARK: Small helpers

    private func positionCaption(metres: Double, instant: Date) -> String {
        if instant < weather.departure {
            return "Waiting at the start \u{2014} departs \(shortTime(weather.departure))"
        }
        if metres >= path.totalDistance - 1 {
            return "Arrived \u{2014} \u{2248}\(shortTime(progress.eta))"
        }
        return "\u{2248}\(Format.distance(metres, unit: settings.units.distance)) along at \(shortTime(instant))"
    }

    private func label(for index: Int, of count: Int, metres: Double) -> String {
        if index == 0 { return "START" }
        if index == count - 1 { return "END" }
        return Format.distance(metres, unit: settings.units.distance)
    }

    private func alignmentTint(_ off: Double?) -> Color {
        guard let off else { return .secondary }
        if off <= 15 { return .green }
        if off <= 30 { return .orange }
        return .red
    }

    private var departureChoices: [Date] {
        let base = RouteWeatherModel.nextWholeHour()
        return (0..<12).map { base.addingTimeInterval(Double($0) * 3600) }
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Saved-route row

/// One saved route in the Favorites panel: name, the line's facts, and a
/// context menu matching the private-spot card's.
struct RouteRow: View {

    let route: PlannedRoute
    let units: UnitPreferences

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(route.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(Format.distance(route.path.totalDistance, unit: units.distance)) · ≈\(Format.duration(route.path.totalDistance / (route.speedKn * 0.5144))) at \(Int(route.speedKn)) kn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
