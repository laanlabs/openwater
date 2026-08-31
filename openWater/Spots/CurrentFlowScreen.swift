import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The water as a field, not a number — the currents twin of the wind
/// flow map, copied from the reference apps' currents screen as closely
/// as the free model allows.
///
/// A blue wash of strength over the water, the model's own arrows on top
/// pointing the way the water *runs* (currents state toward — the one map
/// where a wind habit of +180 would reverse every river), a readout pill
/// at the map's centre saying what the water under it is doing at the
/// scrubbed hour, and the reference timeline below: hour cursor, the
/// set's arrows flipping across slack, bars in the strength ramp, the
/// numbers under their own columns. One batched request fetches the whole
/// day for every point at once; scrubbing never touches the network.
struct CurrentFlowView: View {

    let coordinate: Geo.Coordinate

    @State private var hours: [Date] = []
    @State private var grid: [FlowMapScreen.GridPoint] = []
    /// The station's word for this point, when one stands within
    /// `Currents.stationRadius` — nil everywhere the model speaks alone.
    @State private var station: CurrentsOutlook?
    @State private var scrub: Date?
    @State private var raster: WindRasterOverlay?
    @State private var fieldRegion: MKCoordinateRegion?
    @State private var mapCentre: CLLocationCoordinate2D?
    @State private var isLoading = true
    @State private var loadTask: Task<Void, Never>?

    /// Tighter than the wind flow map's sixty: a tidal race is a local
    /// creature, and forty kilometres of coast is the water one session
    /// can reach.
    private static let spanMetres: Double = 40_000

    private var hour: Int {
        guard !hours.isEmpty else { return 0 }
        let instant = scrub ?? Date()
        return hours.indices.min {
            abs(hours[$0].timeIntervalSince(instant)) < abs(hours[$1].timeIntervalSince(instant))
        } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CurrentFieldMapView(
                centre: coordinate.clCoordinate,
                spanMetres: Self.spanMetres,
                raster: raster,
                arrows: arrowStates,
                station: stationPlace,
                onRegionSettled: { visible in
                    mapCentre = visible.center
                    if needsReload(for: visible) { reload(for: visible) }
                }
            )
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                if isLoading {
                    ProgressView()
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .overlay {
                if let readout = centreReadout {
                    // The reference's centre pill: the set's arrow and the
                    // speed, for wherever the map is dragged, at the
                    // scrubbed hour. On the glass, so the world moves
                    // under it — and on the centre pin's stem and dot, so
                    // the exact water being read is marked, not implied.
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 12, weight: .heavy))
                                .rotationEffect(.degrees(readout.setDeg))
                            Text(String(format: "%.1f", readout.speedKn))
                                .font(.system(size: 17, weight: .bold))
                                .monospacedDigit()
                            + Text(" kt")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        // Dark in both appearances — see CentrePinReadout.
                        .background(Color.mapInk.opacity(0.85), in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                        Rectangle()
                            .fill(Color.mapInk.opacity(0.85))
                            .frame(width: 2, height: 12)
                        Circle()
                            .fill(Color.mapInk.opacity(0.85))
                            .strokeBorder(.white, lineWidth: 2.5)
                            .frame(width: 12, height: 12)
                    }
                    // CentrePinReadout's lift: the stack hangs upward so
                    // the dot's middle sits on the camera's centre.
                    .offset(y: -((34 + 12 + 12) / 2 - 12 / 2))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .allowsHitTesting(false)
                }
            }

            let series = timelineSeries
            if !series.isEmpty {
                DirectionTicksRow(directions: series.map(\.directionDeg),
                                  pointsToward: true, size: 13)
                HStack(alignment: .bottom, spacing: 1) {
                    let peak = max(1.5, (series.compactMap(\.speedKn).max() ?? 0) * 1.2)
                    ForEach(series.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(CurrentPalette.color(for: series[index].speedKn ?? 0))
                            .frame(height: max(2, 56 * (series[index].speedKn ?? 0) / peak))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: 56, alignment: .bottom)
                ValueTicksRow(values: series.map(\.speedKn))
                HourScrubber(hours: series.map(\.at), timeZone: .current, selection: $scrub)
            } else if !isLoading {
                Text("No current model on this water — the ocean model has no cell here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let station, !station.events.isEmpty {
                turnChips(for: station)
            }

            if case .station(let noaa)? = station?.source {
                // The tide caption's grammar, for its sibling: whose
                // numbers, how far, and that a harmonic table is still a
                // prediction. Tappable through to the station's own page.
                Link(destination: noaa.url) {
                    Text("\(station?.hours.isEmpty == false ? "Bars and turns" : "The turns"): NOAA CO-OPS predictions for \(noaa.name), \(Format.distance(noaa.metres, unit: .metric)) from here — the authority on speed and slack; still a prediction, not measured.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(station == nil
                 ? "Open-Meteo's ocean model — modeled, not observed · CC-BY 4.0. Arrows point the way the water runs; the wash deepens with strength. Pan and the field refetches; scrub through the next day."
                 : "The map's wash and arrows stay Open-Meteo's ocean model — modeled, not observed · CC-BY 4.0. Two authorities, never mixed: the station owns the timeline, the model owns the field.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            station = await Currents.station(at: coordinate)
        }
        .task {
            // The map's first settle triggers the first fetch; this is the
            // belt for a layout that never reports one.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if fieldRegion == nil, loadTask == nil {
                reload(for: MKCoordinateRegion(
                    center: coordinate.clCoordinate,
                    latitudinalMeters: Self.spanMetres,
                    longitudinalMeters: Self.spanMetres))
            }
        }
        .onChange(of: hour) { _, _ in rebuildRaster() }
    }

    // MARK: The field

    private var arrowStates: [CurrentFieldMapView.Arrow] {
        grid.compactMap { point in
            guard let speed = point.speeds[safe: hour] ?? nil,
                  let set = point.directions[safe: hour] ?? nil
            else { return nil }
            return CurrentFieldMapView.Arrow(
                id: point.id,
                coordinate: point.coordinate.clCoordinate,
                speedKn: speed,
                setDeg: set)
        }
    }

    /// The series the timeline charts. A station inside
    /// `Currents.stationRadius` owns it wholesale — its rows laid onto the
    /// field's axis so the one scrubber drives bars and raster together,
    /// or on the station's own axis when the model has no cell here at
    /// all. Everywhere else, the grid point nearest the map's centre.
    private var timelineSeries: [CurrentsOutlook.Hour] {
        if let station, !station.hours.isEmpty {
            if hours.isEmpty { return station.hours }
            let aligned = CurrentsOutlook.aligned(station.hours, to: hours)
            // Nothing landed in a single slot — the two clocks disagree —
            // and an all-blank chart is not an authority either.
            if aligned.contains(where: { $0.speedKn != nil }) { return aligned }
        }
        return centreSeries
    }

    /// Where the station's numbers are measured from, for the map — 600 m
    /// away does not say which side of the channel.
    private var stationPlace: (coordinate: CLLocationCoordinate2D, name: String)? {
        guard case .station(let noaa)? = station?.source else { return nil }
        return (noaa.coordinate.clCoordinate, noaa.name)
    }

    /// The turns of the water in the station's own words — max flood,
    /// slack, max ebb — the one thing the model can never say. The removed
    /// panel's chip row, verbatim.
    private func turnChips(for station: CurrentsOutlook) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(station.events.filter { $0.at > Date().addingTimeInterval(-3600) }.prefix(8)) { event in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(eventLabel(event.kind))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(eventTint(event.kind))
                        Text(shortTime(event.at, zone: station.timeZone))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        + Text(event.speedKn.map { String(format: " · %.1f kn", $0) } ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func eventLabel(_ kind: CurrentsOutlook.Event.Kind) -> String {
        switch kind {
        case .maxFlood: "MAX FLOOD"
        case .maxEbb: "MAX EBB"
        case .slack: "SLACK"
        }
    }

    private func eventTint(_ kind: CurrentsOutlook.Event.Kind) -> Color {
        switch kind {
        case .maxFlood: .accentColor
        case .maxEbb: .orange
        case .slack: .secondary
        }
    }

    private func shortTime(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone ?? .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The model's series: the grid point nearest the map's centre — the
    /// same water the pill reads.
    private var centreSeries: [CurrentsOutlook.Hour] {
        guard let nearest = nearestGridPoint else { return [] }
        return hours.indices.map { index in
            CurrentsOutlook.Hour(at: hours[index],
                                 speedKn: nearest.speeds[safe: index] ?? nil,
                                 directionDeg: nearest.directions[safe: index] ?? nil)
        }
    }

    private var centreReadout: (speedKn: Double, setDeg: Double)? {
        guard let nearest = nearestGridPoint,
              let speed = nearest.speeds[safe: hour] ?? nil,
              let set = nearest.directions[safe: hour] ?? nil
        else { return nil }
        return (speed, set)
    }

    private var nearestGridPoint: FlowMapScreen.GridPoint? {
        let centre = mapCentre.map { Geo.Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            ?? coordinate
        return grid
            .filter { $0.speeds.contains { $0 != nil } }
            .min {
                Geo.distance(centre, $0.coordinate) < Geo.distance(centre, $1.coordinate)
            }
    }

    /// The wind flow map's drift rule, verbatim.
    private func needsReload(for visible: MKCoordinateRegion) -> Bool {
        guard let field = fieldRegion else { return true }
        let spanRatio = visible.span.latitudeDelta / field.span.latitudeDelta
        let centreShift =
            abs(visible.center.latitude - field.center.latitude) / field.span.latitudeDelta
            + abs(visible.center.longitude - field.center.longitude) / field.span.longitudeDelta
        return spanRatio > 1.3 || spanRatio < 0.55 || centreShift > 0.3
    }

    private func reload(for visible: MKCoordinateRegion) {
        var target = visible
        target.span.latitudeDelta *= 1.2
        target.span.longitudeDelta *= 1.2
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            var coords: [Geo.Coordinate] = []
            for row in 0..<FlowMapScreen.rows {
                for column in 0..<FlowMapScreen.columns {
                    coords.append(Geo.Coordinate(
                        latitude: max(-89, min(89,
                            target.center.latitude - target.span.latitudeDelta / 2
                            + target.span.latitudeDelta * Double(row) / Double(FlowMapScreen.rows - 1))),
                        longitude: target.center.longitude - target.span.longitudeDelta / 2
                            + target.span.longitudeDelta * Double(column) / Double(FlowMapScreen.columns - 1)
                    ))
                }
            }
            let field = await OpenMeteo.marineAlong(coords, hours: 24)
            guard !Task.isCancelled else { return }
            let axis = field.map(\.currents).max(by: { $0.count < $1.count })?.map(\.at) ?? []
            hours = axis
            grid = coords.indices.compactMap { index -> FlowMapScreen.GridPoint? in
                guard let rows = field[safe: index]?.currents, !rows.isEmpty else { return nil }
                var speeds = [Double?](repeating: nil, count: axis.count)
                var directions = [Double?](repeating: nil, count: axis.count)
                for row in rows {
                    guard let slot = axis.firstIndex(of: row.at) else { continue }
                    speeds[slot] = row.speedKn
                    directions[slot] = row.directionDeg
                }
                return FlowMapScreen.GridPoint(id: index, coordinate: coords[index],
                                               speeds: speeds, directions: directions)
            }
            fieldRegion = target
            rebuildRaster()
            withAnimation(.easeOut(duration: 0.2)) { isLoading = false }
        }
    }

    private func rebuildRaster() {
        guard let fieldRegion else { return }
        raster = WindRasterOverlay.build(
            grid: grid, hour: hour,
            columns: FlowMapScreen.columns, rows: FlowMapScreen.rows,
            region: fieldRegion,
            palette: { CurrentPalette.washColour(for: $0) }
        )
    }
}

// MARK: - The map

/// MKMapView under the SwiftUI, for the same reason as the wind flow map:
/// the wash is a geo-registered image and SwiftUI's `Map` cannot draw one.
private struct CurrentFieldMapView: UIViewRepresentable {

    struct Arrow {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let speedKn: Double
        let setDeg: Double
    }

    let centre: CLLocationCoordinate2D
    let spanMetres: Double
    let raster: WindRasterOverlay?
    let arrows: [Arrow]
    let station: (coordinate: CLLocationCoordinate2D, name: String)?
    let onRegionSettled: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(MKCoordinateRegion(
            center: centre,
            latitudinalMeters: spanMetres * 1.15,
            longitudinalMeters: spanMetres * 1.15
        ), animated: false)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        // The basemap stays light whatever the app is wearing.
        //
        // Everything drawn on this map assumes a pale ground: the wash's own
        // palette starts at white for calm and `arrowNeutral` is a dark grey.
        // MapKit's dark basemap answers that with white place names, and they
        // land on the pale wash rather than under it — measured at 2.0:1
        // against it, which is not a label, it is a rumour. The map is already
        // bright wherever the field covers it, so lighting the ground under it
        // is the coherent half of the choice, not the loud one; the screen
        // around it stays dark.
        map.overrideUserInterfaceStyle = .light
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onRegionSettled = onRegionSettled
        if context.coordinator.rasterID != raster?.id {
            context.coordinator.rasterID = raster?.id
            map.removeOverlays(map.overlays)
            if let raster { map.addOverlay(raster) }
        }
        let key = arrows
            .map { "\($0.id):\(Int($0.speedKn * 10)):\(Int($0.setDeg))" }
            .joined(separator: ",")
        if context.coordinator.arrowsKey != key {
            context.coordinator.arrowsKey = key
            // Arrows only — the station's dot is not the field's to wipe.
            map.removeAnnotations(map.annotations.filter { $0 is CurrentArrowAnnotation })
            map.addAnnotations(arrows.map(CurrentArrowAnnotation.init))
        }
        let stationKey = station.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" } ?? ""
        if context.coordinator.stationKey != stationKey {
            context.coordinator.stationKey = stationKey
            map.removeAnnotations(map.annotations.filter { $0 is CurrentStationAnnotation })
            if let station {
                map.addAnnotation(CurrentStationAnnotation(
                    coordinate: station.coordinate, name: station.name))
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var rasterID: UUID?
        var arrowsKey = ""
        var stationKey = ""
        var onRegionSettled: (MKCoordinateRegion) -> Void = { _ in }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionSettled(mapView.region)
        }

        func mapView(_ mapView: MKMapView,
                     rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            (overlay as? WindRasterOverlay).map(WindRasterImageRenderer.init)
                ?? MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView,
                     viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is CurrentStationAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "current-station")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "current-station")
                view.annotation = annotation
                view.image = CurrentStationSprite.image
                view.canShowCallout = true
                return view
            }
            guard let arrow = annotation as? CurrentArrowAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "current-arrow")
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "current-arrow")
            view.annotation = annotation
            view.image = CurrentArrowSprite.image(speedKn: arrow.speedKn, setDeg: arrow.setDeg)
            view.isEnabled = false
            return view
        }
    }
}

/// Where the station stands, named — tapping the dot says which channel
/// edge the numbers belong to.
private final class CurrentStationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(coordinate: CLLocationCoordinate2D, name: String) {
        self.coordinate = coordinate
        self.title = name
    }
}

/// The station's dot: small on purpose — a landmark, not a reading — in
/// the centre pill's own colours so it reads as the app's, not the map's.
private enum CurrentStationSprite {
    static let image: UIImage = {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cg = rendererContext.cgContext
            cg.setShadow(offset: .zero, blur: 2,
                         color: UIColor.black.withAlphaComponent(0.4).cgColor)
            cg.setFillColor(UIColor.black.withAlphaComponent(0.85).cgColor)
            cg.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: CGRect(x: 2.75, y: 2.75, width: 10.5, height: 10.5))
        }
    }()
}

private final class CurrentArrowAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let speedKn: Double
    let setDeg: Double

    init(_ arrow: CurrentFieldMapView.Arrow) {
        self.coordinate = arrow.coordinate
        self.speedKn = arrow.speedKn
        self.setDeg = arrow.setDeg
    }
}

/// The renderer, shared shape with the wind flow map's: UIImage.draw for
/// the flipped-context reason documented there.
private final class WindRasterImageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? WindRasterOverlay else { return }
        let rect = rect(for: overlay.boundingMapRect)
        UIGraphicsPushContext(context)
        UIImage(cgImage: overlay.image).draw(in: rect)
        UIGraphicsPopContext()
    }
}

/// White arrows over the blue wash, the reference's own contrast — set
/// direction as-is, tenths of a knot underneath, a dark halo so they stay
/// readable over the palest slack.
private enum CurrentArrowSprite {

    static func image(speedKn: Double, setDeg: Double) -> UIImage {
        let size = CGSize(width: 36, height: 46)
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cg = rendererContext.cgContext
            cg.setShadow(offset: .zero, blur: 3,
                         color: UIColor.black.withAlphaComponent(0.55).cgColor)

            let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            if speedKn < 0.1 {
                // Slack: a direction would be noise.
                let dot = UIImage(systemName: "circle.dotted", withConfiguration: configuration)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                dot?.draw(at: CGPoint(x: (size.width - (dot?.size.width ?? 0)) / 2, y: 6))
            } else if let arrow = UIImage(systemName: "arrow.up", withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                cg.saveGState()
                cg.translateBy(x: size.width / 2, y: 15)
                cg.rotate(by: setDeg * .pi / 180)
                arrow.draw(in: CGRect(x: -arrow.size.width / 2, y: -arrow.size.height / 2,
                                      width: arrow.size.width, height: arrow.size.height))
                cg.restoreGState()

                let text = String(format: "%.1f", speedKn) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
                let width = text.size(withAttributes: attributes).width
                text.draw(at: CGPoint(x: (size.width - width) / 2, y: 32),
                          withAttributes: attributes)
            }
        }
    }
}
