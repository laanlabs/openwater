import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The wind as a field, not a number.
///
/// A single forecast says what the wind is here; a flow map says what it is
/// doing — the sea breeze filling from the south shore, the gradient dying
/// in the lee of the hills, the line where two of them argue. This is that
/// view from the same free model the rest of the sheet reads: a colour wash
/// of strength over the water with the model's own arrows on top, and a
/// scrubber through the next day.
///
/// The arrows sit at the ~10 km spacing the model actually computes and
/// carry its real numbers. The colour between them is a smooth blend of
/// those same values — the shading is interpolation for the eye, not extra
/// detail, and the footnote says so. One batched request fetches the whole
/// day for every point at once.
struct FlowMapScreen: View {

    let title: String
    let coordinate: Geo.Coordinate

    @State private var hours: [Date] = []
    @State private var grid: [GridPoint] = []
    @State private var hourIndex: Double = 0
    @State private var raster: WindRasterOverlay?
    @State private var isLoading = true
    /// What the field currently covers. Pan or zoom far enough outside it
    /// and the whole thing refetches to match the new view.
    @State private var fieldRegion: MKCoordinateRegion?
    @State private var loadTask: Task<Void, Never>?
    /// The colour wash, on by default and remembered — some riders read
    /// fields, some read arrows, and neither should have to re-choose.
    @AppStorage("flowMap.colourWash") private var showWash = true
    /// The app-wide wind model, editable from this screen's own caption.
    @AppStorage("spots.forecastModel") private var forecastModelRaw = ForecastModel.automatic.rawValue
    @State private var isPickingModel = false

    /// Compact height is a phone turned on its side, and a wind field is a
    /// picture of a coastline — wider than it is tall. Sideways the map takes
    /// the screen: no navigation bar, and the scrubber floats over the water
    /// instead of pushing it up.
    @Environment(\.verticalSizeClass) private var height
    @Environment(\.dismiss) private var dismiss

    private var landscape: Bool { height == .compact }

    struct GridPoint: Identifiable {
        /// Row-major position in the grid — the raster builder needs to
        /// know which cell this is, not just where it sits.
        let id: Int
        let coordinate: Geo.Coordinate
        /// Knots and degrees-from, aligned to `hours`.
        let speeds: [Double?]
        let directions: [Double?]
    }

    private var hour: Int { Int(hourIndex.rounded()) }

    var body: some View {
        WindFieldMapView(
            centre: coordinate.clCoordinate,
            spanMetres: Self.spanMetres,
            raster: showWash ? raster : nil,
            arrows: arrowStates,
            arrowsNeutral: showWash,
            onRegionSettled: { visible in
                if needsReload(for: visible) { reload(for: visible) }
            }
        )
        .ignoresSafeArea(edges: landscape ? .all : [])
        .navigationTitle("Flow map")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Flow map")
        .toolbar(landscape ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(landscape)
        .allowsLandscape()
        .safeAreaInset(edge: .bottom) {
            if !landscape { controls }
        }
        .overlay(alignment: .bottom) {
            if landscape {
                controls
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        }
        .overlay(alignment: .topLeading) {
            // The navigation bar's back button went with the bar. This is the
            // way out, in the corner it was in.
            if landscape {
                MapChromeButton {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .padding(.leading, 16)
                .padding(.top, 10)
                .accessibilityLabel("Back")
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await load() }
        .onChange(of: hour) { _, _ in rebuildRaster() }
        .sheet(isPresented: $isPickingModel) {
            ForecastModelSheet(selection: $forecastModelRaw)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: forecastModelRaw) { _, _ in
            // A different model is a different field; the one on screen was
            // answered by the old one.
            guard let region = fieldRegion else { return }
            fieldRegion = nil
            reload(for: region)
        }
    }

    private var arrowStates: [WindFieldMapView.Arrow] {
        grid.compactMap { point in
            guard let speed = point.speeds[safe: hour] ?? nil,
                  let direction = point.directions[safe: hour] ?? nil
            else { return nil }
            return WindFieldMapView.Arrow(
                id: point.id,
                coordinate: point.coordinate.clCoordinate,
                speedKn: speed,
                directionFromDeg: direction
            )
        }
    }

    // MARK: The scrubber

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(hourLabel)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                if hour == 0 {
                    Text("now")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
                Spacer()
                Toggle(isOn: $showWash) {
                    Label("Colour", systemImage: "square.3.layers.3d")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            if hours.count > 1 {
                Slider(value: $hourIndex, in: 0...Double(hours.count - 1), step: 1)
            }

            if showWash { washLegend } else { legend }

            // Whose model this is, and the door to changing it — the
            // reference apps put the picker exactly here, on the name. Both
            // it and the paragraph under it stay behind in portrait: sideways
            // the map is the point, and neither is what a rider turned the
            // phone for.
            if !landscape {
                Button { isPickingModel = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.caption2.weight(.semibold))
                        Text(ForecastModel.selected.name)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Text("The arrows are the model's own values; the "
                     + "colour between them is a smooth blend of those values for the "
                     + "eye, not extra detail. Pan or zoom and the field refetches to "
                     + "match — far out, the wash's edge marks the area it covers. "
                     + "Scrub through the next 24 hours.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(landscape ? 10 : 14)
        .background(.regularMaterial)
    }

    /// The wash's own key: the whole ramp as a bar, knots ticked under the
    /// band edges a rider actually plans around.
    private var washLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                ForEach(Array(WindPalette.washBands.enumerated()), id: \.offset) { _, band in
                    Rectangle()
                        .fill(Color(uiColor: band.colour))
                        .frame(height: 8)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color(.systemGray4), lineWidth: 0.5))

            HStack {
                Text("0")
                Spacer()
                Text("8")
                Spacer()
                Text("16")
                Spacer()
                Text("25")
                Spacer()
                Text("32+ kn")
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var hourLabel: String {
        guard let date = hours[safe: hour] else { return "—" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var legend: some View {
        HStack(spacing: 5) {
            ForEach(Self.legendSteps, id: \.label) { step in
                HStack(spacing: 2) {
                    Circle()
                        .fill(step.colour)
                        .frame(width: 7, height: 7)
                    Text(step.label)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let legendSteps: [(label: String, colour: Color)] = [
        ("<8", Color(uiColor: WindPalette.colour(for: 5))),
        ("8+", Color(uiColor: WindPalette.colour(for: 10))),
        ("12+", Color(uiColor: WindPalette.colour(for: 13))),
        ("15+", Color(uiColor: WindPalette.colour(for: 17))),
        ("21+", Color(uiColor: WindPalette.colour(for: 22))),
    ]

    // MARK: The field

    /// About sixty kilometres of coast — the water a rider would actually
    /// drive along, at a span where ~10 km arrows still read as a field.
    static let spanMetres: Double = 60_000
    // The grid itself lives in `WindField`, shared with the wash — both
    // draw the same field and it is not either screen's number to own.
    nonisolated static var columns: Int { WindField.columns }
    nonisolated static var rows: Int { WindField.rows }

    /// Whether the view has wandered far enough from the loaded field to
    /// deserve a fresh one. Nil field means nothing loaded yet — the first
    /// settle after the map lays out triggers the first fetch.
    private func needsReload(for visible: MKCoordinateRegion) -> Bool {
        guard let field = fieldRegion else { return true }
        let spanRatio = visible.span.latitudeDelta / field.span.latitudeDelta
        let centreShift =
            abs(visible.center.latitude - field.center.latitude) / field.span.latitudeDelta
            + abs(visible.center.longitude - field.center.longitude) / field.span.longitudeDelta
        return spanRatio > 1.3 || spanRatio < 0.55 || centreShift > 0.3
    }

    /// The field the view deserves: a fifth wider than what is visible, so
    /// the arrows run clean past the bezels and the wash's feathered edge
    /// stays offscreen. Never tighter than the model's own ~10 km grid can
    /// honestly fill, and capped only at continental scale — the fetch
    /// costs the same sixty-three points at any span, so the cap exists
    /// for sense, not thrift. Past it, the feathered edge is the box that
    /// says where the field ends.
    private func clampedField(for visible: MKCoordinateRegion) -> MKCoordinateRegion {
        var region = visible
        region.span.latitudeDelta *= 1.2
        region.span.longitudeDelta *= 1.2
        let latMetres = region.span.latitudeDelta * 110_574
        let clamped = min(max(latMetres, 45_000), 2_500_000)
        let scale = clamped / latMetres
        region.span.latitudeDelta = min(region.span.latitudeDelta * scale, 120)
        region.span.longitudeDelta = min(region.span.longitudeDelta * scale, 340)
        return region
    }

    private func reload(for visible: MKCoordinateRegion) {
        let target = clampedField(for: visible)
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            let coords = gridCoordinates(for: target)
            let field = await OpenMeteo.windAlong(coords, hours: 24)
            guard !Task.isCancelled else { return }
            // The time axis from the densest answer — cells the model has
            // no data for simply keep their nils.
            let axis = field.max(by: { $0.count < $1.count })?.map(\.date) ?? []
            hours = axis
            hourIndex = min(hourIndex, Double(max(0, axis.count - 1)))
            grid = coords.indices.compactMap { index -> GridPoint? in
                guard let rows = field[safe: index], !rows.isEmpty else { return nil }
                var speeds = [Double?](repeating: nil, count: axis.count)
                var directions = [Double?](repeating: nil, count: axis.count)
                for row in rows {
                    guard let slot = axis.firstIndex(of: row.date) else { continue }
                    speeds[slot] = row.speedKn
                    directions[slot] = row.directionDeg
                }
                return GridPoint(id: index, coordinate: coords[index],
                                 speeds: speeds, directions: directions)
            }
            fieldRegion = target
            rebuildRaster()
            withAnimation(.easeOut(duration: 0.2)) { isLoading = false }
        }
    }

    private func load() async {
        // The map's first settle normally triggers the first fetch; this is
        // the belt for the day layout never reports one.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if fieldRegion == nil, loadTask == nil {
            reload(for: MKCoordinateRegion(
                center: coordinate.clCoordinate,
                latitudinalMeters: Self.spanMetres,
                longitudinalMeters: Self.spanMetres))
        }
    }

    private func rebuildRaster() {
        guard let fieldRegion else { return }
        raster = WindRasterOverlay.build(
            grid: grid, hour: hour,
            columns: Self.columns, rows: Self.rows,
            region: fieldRegion
        )
    }

    private func gridCoordinates(for region: MKCoordinateRegion) -> [Geo.Coordinate] {
        var out: [Geo.Coordinate] = []
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                out.append(Geo.Coordinate(
                    latitude: max(-89, min(89,
                        region.center.latitude - region.span.latitudeDelta / 2
                        + region.span.latitudeDelta * Double(row) / Double(Self.rows - 1))),
                    longitude: region.center.longitude - region.span.longitudeDelta / 2
                        + region.span.longitudeDelta * Double(column) / Double(Self.columns - 1)
                ))
            }
        }
        return out
    }
}

// MARK: - The colours

// MARK: - The map

/// MKMapView under the SwiftUI: the one thing the SwiftUI `Map` cannot do
/// yet is draw a geo-registered image, and the colour wash is exactly that.
private struct WindFieldMapView: UIViewRepresentable {

    struct Arrow {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let speedKn: Double
        let directionFromDeg: Double
    }

    let centre: CLLocationCoordinate2D
    let spanMetres: Double
    let raster: WindRasterOverlay?
    let arrows: [Arrow]
    /// Dark slate arrows when the wash carries the colour; the app's own
    /// speed ramp when the arrows are on their own.
    let arrowsNeutral: Bool
    /// Called when a pan or zoom settles, with the region now on screen.
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

        let here = MKPointAnnotation()
        here.coordinate = centre
        map.addAnnotation(here)
        context.coordinator.hereAnnotation = here
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onRegionSettled = onRegionSettled
        if context.coordinator.rasterID != raster?.id {
            context.coordinator.rasterID = raster?.id
            map.removeOverlays(map.overlays)
            if let raster { map.addOverlay(raster) }
        }
        // Rebuilt whole when the hour (or the data behind it) changes —
        // sixty-odd tiny annotation views are cheap, and diffing them by
        // hand would not be.
        let key = "\(arrowsNeutral):" + arrows
            .map { "\($0.id):\(Int($0.speedKn)):\(Int($0.directionFromDeg))" }
            .joined(separator: ",")
        if context.coordinator.arrowsKey != key {
            context.coordinator.arrowsKey = key
            context.coordinator.arrowsNeutral = arrowsNeutral
            let keep = context.coordinator.hereAnnotation.map { [$0] } ?? []
            map.removeAnnotations(map.annotations)
            map.addAnnotations(keep)
            map.addAnnotations(arrows.map(ArrowAnnotation.init))
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var rasterID: UUID?
        var arrowsKey = ""
        var arrowsNeutral = true
        var hereAnnotation: MKPointAnnotation?
        var onRegionSettled: (MKCoordinateRegion) -> Void = { _ in }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionSettled(mapView.region)
        }

        func mapView(_ mapView: MKMapView,
                     rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            (overlay as? WindRasterOverlay).map(WindRasterRenderer.init)
                ?? MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView,
                     viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let arrow = annotation as? ArrowAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "arrow")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "arrow")
                view.annotation = annotation
                view.image = ArrowSprite.image(speedKn: arrow.speedKn,
                                               directionFromDeg: arrow.directionFromDeg,
                                               neutral: arrowsNeutral)
                view.isEnabled = false
                return view
            }
            // The blue "you are here" dot.
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "here")
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "here")
            view.annotation = annotation
            view.image = ArrowSprite.hereDot
            view.isEnabled = false
            return view
        }
    }
}

/// One arrow of the field as an annotation.
private final class ArrowAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let speedKn: Double
    let directionFromDeg: Double

    init(_ arrow: WindFieldMapView.Arrow) {
        self.coordinate = arrow.coordinate
        self.speedKn = arrow.speedKn
        self.directionFromDeg = arrow.directionFromDeg
    }
}

/// The arrow images, drawn with plain UIKit: pointing the way the wind
/// blows, coloured by how hard, the knots underneath — with a pale halo so
/// they stay readable over any colour the wash puts behind them.
private enum ArrowSprite {

    static func image(speedKn: Double, directionFromDeg: Double, neutral: Bool) -> UIImage {
        let size = CGSize(width: 36, height: 46)
        let colour = neutral ? WindPalette.arrowNeutral : WindPalette.colour(for: speedKn)
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cg = rendererContext.cgContext
            cg.setShadow(offset: .zero, blur: 3,
                         color: UIColor.white.withAlphaComponent(0.9).cgColor)

            let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            if speedKn < 2 {
                // Near calm: a direction would be noise, so no arrow at all.
                let dot = UIImage(systemName: "circle.dotted", withConfiguration: configuration)?
                    .withTintColor(colour, renderingMode: .alwaysOriginal)
                dot?.draw(at: CGPoint(x: (size.width - (dot?.size.width ?? 0)) / 2, y: 6))
            } else if let arrow = UIImage(systemName: "arrow.up", withConfiguration: configuration)?
                .withTintColor(colour, renderingMode: .alwaysOriginal) {
                cg.saveGState()
                cg.translateBy(x: size.width / 2, y: 15)
                cg.rotate(by: (directionFromDeg + 180) * .pi / 180)
                arrow.draw(in: CGRect(x: -arrow.size.width / 2, y: -arrow.size.height / 2,
                                      width: arrow.size.width, height: arrow.size.height))
                cg.restoreGState()

                let text = "\(Int(speedKn.rounded()))" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: colour,
                ]
                let width = text.size(withAttributes: attributes).width
                text.draw(at: CGPoint(x: (size.width - width) / 2, y: 32),
                          withAttributes: attributes)
            }
        }
    }

    static let hereDot: UIImage = {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setFillColor((UIColor(named: "AccentColor") ?? .systemBlue).cgColor)
            cg.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(2)
            cg.strokeEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
        }
    }()
}

// MARK: - The colour wash

/// The speed field as a geo-registered image: the grid's values bilinearly
/// blended to a small bitmap, stepped through the palette, drawn at ~45%
/// over the map. Banding is deliberate — smooth contours between honest
/// levels, the way every wind map draws them.
final class WindRasterOverlay: NSObject, MKOverlay {

    let image: CGImage
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let id = UUID()

    private init(image: CGImage, coordinate: CLLocationCoordinate2D, rect: MKMapRect) {
        self.image = image
        self.coordinate = coordinate
        self.boundingMapRect = rect
    }

    /// Nil until there is a field worth painting. The palette is a
    /// parameter since the currents flow map arrived: same raster walk,
    /// different quantity, different colours.
    static func build(grid: [FlowMapScreen.GridPoint], hour: Int,
                      columns: Int, rows: Int,
                      region: MKCoordinateRegion,
                      palette: (Double) -> UIColor = { WindPalette.washColour(for: $0) }) -> WindRasterOverlay? {
        guard !grid.isEmpty else { return nil }

        // Speeds by grid cell, row-major as the fetch built them.
        var speeds = [Double?](repeating: nil, count: columns * rows)
        for point in grid where point.id < speeds.count {
            speeds[point.id] = point.speeds[safe: hour] ?? nil
        }
        guard speeds.contains(where: { $0 != nil }) else { return nil }

        // A small bitmap is plenty: the source is 7×9 numbers, and the
        // upsampling is for smooth contours, not resolution.
        let width = 168, height = 216
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let washAlpha: CGFloat = 0.55
        // The field fades out over its outer edge instead of ending on a
        // hard rectangle — the model keeps going, this window just stops.
        let featherPx: Double = 14

        func speed(atColumn column: Int, row: Int) -> Double? {
            speeds[row * columns + column]
        }

        for py in 0..<height {
            // Image row 0 is the north edge; grid row 0 is the south.
            let gy = (1 - Double(py) / Double(height - 1)) * Double(rows - 1)
            let row0 = min(Int(gy), rows - 2)
            let ty = gy - Double(row0)
            let edgeY = min(Double(py), Double(height - 1 - py))
            for px in 0..<width {
                let gx = Double(px) / Double(width - 1) * Double(columns - 1)
                let column0 = min(Int(gx), columns - 2)
                let tx = gx - Double(column0)

                guard let a = speed(atColumn: column0, row: row0),
                      let b = speed(atColumn: column0 + 1, row: row0),
                      let c = speed(atColumn: column0, row: row0 + 1),
                      let d = speed(atColumn: column0 + 1, row: row0 + 1)
                else { continue }
                let blended = (a * (1 - tx) + b * tx) * (1 - ty)
                    + (c * (1 - tx) + d * tx) * ty

                let edge = min(edgeY, min(Double(px), Double(width - 1 - px)))
                let alpha = washAlpha * CGFloat(min(1, edge / featherPx))

                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, opacity: CGFloat = 0
                palette(blended).getRed(&red, green: &green, blue: &blue, alpha: &opacity)
                let offset = (py * width + px) * 4
                // Premultiplied, so the renderer can draw it straight.
                pixels[offset] = UInt8(red * alpha * 255)
                pixels[offset + 1] = UInt8(green * alpha * 255)
                pixels[offset + 2] = UInt8(blue * alpha * 255)
                pixels[offset + 3] = UInt8(alpha * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }

        // The overlay's rect spans the outermost grid points.
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let rect = MKMapRect(
            x: northWest.x, y: northWest.y,
            width: southEast.x - northWest.x, height: southEast.y - northWest.y)

        return WindRasterOverlay(
            image: image,
            coordinate: region.center,
            rect: rect)
    }
}

private final class WindRasterRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? WindRasterOverlay else { return }
        let rect = rect(for: overlay.boundingMapRect)
        // UIImage.draw respects the renderer's flipped coordinates, which
        // a bare CGContext.draw would not — the classic upside-down-overlay
        // bug, avoided rather than debugged.
        UIGraphicsPushContext(context)
        UIImage(cgImage: overlay.image).draw(in: rect)
        UIGraphicsPopContext()
    }
}
