import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// One sample of a list preview: where, and how fast.
struct PreviewSample: Hashable, Sendable {
    var coordinate: CLLocationCoordinate2D
    var speed: Double

    static func == (a: PreviewSample, b: PreviewSample) -> Bool {
        a.speed == b.speed
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
        hasher.combine(speed)
    }

    /// Unpack the `latitude, longitude, speed` triples stored on a session.
    static func decode(_ flattened: [Double]) -> [PreviewSample] {
        stride(from: 0, to: flattened.count - 2, by: 3).map {
            PreviewSample(
                coordinate: CLLocationCoordinate2D(
                    latitude: flattened[$0],
                    longitude: flattened[$0 + 1]
                ),
                speed: flattened[$0 + 2]
            )
        }
    }
}

/// The speed ramp, shared by the thumbnail, the full map, the legend and the
/// share image.
///
/// Three stops, interpolated in RGB: red at a standstill, yellow at fifteen
/// knots, green at twenty-five and above. Reversed from the usual convention on
/// purpose — on the water the interesting question is "where was I going well",
/// and green reads as *good* rather than as *slow*. The gybes come out red,
/// which is exactly where the speed went.
///
/// The values are fitted from Waterspeed's rendering of a track we also hold,
/// to within a few units of 255 across its whole range. Matching a tool riders
/// already read fluently beats being subtly different for no reason.
private let speedRampStops: [(Double, Double, Double)] = [
    (231, 54, 47),     // #e7362f — a standstill
    (238, 211, 69),    // #eed345 — the session's mean speed
    (127, 174, 65),    // #7fae41 — its 97th percentile and above
]

/// The ramp's colour at a position along it, 0–1.
///
/// The middle stop sits at `midpoint` rather than halfway, because the middle
/// of this ramp is the session's mean speed and that is rarely the middle of
/// its range. Passing it in is what keeps the two halves — below average and
/// above it — from being stretched to the same width.
///
/// Interpolated in RGB rather than through hue. It matters: a hue sweep between
/// the same endpoints passes through colours that are not on the line between
/// them — red to yellow goes via a vivid orange that neither stop contains —
/// and the result stops matching the thing being copied.
func speedRampColour(position t: Double, midpoint: Double) -> UIColor {
    let t = max(0, min(1, t))
    let mid = max(0.05, min(0.95, midpoint))
    let (a, b, f): ((Double, Double, Double), (Double, Double, Double), Double) =
        t <= mid
        ? (speedRampStops[0], speedRampStops[1], mid > 0 ? t / mid : 0)
        : (speedRampStops[1], speedRampStops[2], mid < 1 ? (t - mid) / (1 - mid) : 0)

    return UIColor(
        red: (a.0 + (b.0 - a.0) * f) / 255,
        green: (a.1 + (b.1 - a.1) * f) / 255,
        blue: (a.2 + (b.2 - a.2) * f) / 255,
        alpha: 1
    )
}

func speedRampColour(_ speed: Double, scale: SpeedScale) -> UIColor {
    speedRampColour(position: scale.position(of: speed), midpoint: scale.midpoint)
}

/// A static map image of a session's track, for the session list.
///
/// A live `Map` per row would be a MapKit view per row — several of them
/// scrolling at once is the single most reliable way to make a list stutter.
/// `MKMapSnapshotter` renders once to a bitmap that scrolls like any other
/// image, and the result is cached on disk so the second launch does not go
/// back to the network.
///
/// The track is drawn over the snapshot rather than through an overlay renderer
/// because a snapshotter has no overlay support: it hands back a bitmap and a
/// coordinate-to-point function, and everything else is ours to draw.
@MainActor
final class TrackThumbnailCache {

    static let shared = TrackThumbnailCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private lazy var directory: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = base.appendingPathComponent("track-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        memory.countLimit = 80
    }

    /// Render, or return a cached image.
    ///
    /// The key includes the point count and the map style: a session that gets
    /// re-analysed or trimmed produces a different track, and a stale thumbnail
    /// showing the old shape would be worse than none.
    func image(
        id: UUID,
        samples: [PreviewSample],
        size: CGSize,
        style: MapStyleOption,
        scale: CGFloat
    ) async -> UIImage? {
        guard samples.count > 1, size.width > 1, size.height > 1 else { return nil }

        let key = "\(id.uuidString)-\(samples.count)-\(style.rawValue)-\(Int(size.width))x\(Int(size.height))@\(Int(scale))"

        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        if let url = directory?.appendingPathComponent(key + ".png"),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data, scale: scale) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        let task = Task<UIImage?, Never> { [weak self] in
            let image = await Self.render(samples: samples, size: size, style: style, scale: scale)
            if let image, let self {
                self.memory.setObject(image, forKey: key as NSString)
                if let url = self.directory?.appendingPathComponent(key + ".png"),
                   let data = image.pngData() {
                    try? data.write(to: url, options: .atomic)
                }
            }
            self?.inFlight[key] = nil
            return image
        }
        inFlight[key] = task
        return await task.value
    }

    // MARK: - Rendering

    private static func render(
        samples: [PreviewSample],
        size: CGSize,
        style: MapStyleOption,
        scale: CGFloat
    ) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = region(for: samples.map(\.coordinate))
        options.size = size
        options.traitCollection = UITraitCollection(displayScale: scale)
        options.pointOfInterestFilter = .excludingAll

        switch style {
        case .standard: options.mapType = .mutedStandard
        case .hybrid: options.mapType = .hybrid
        case .imagery: options.mapType = .satellite
        }

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let points = samples.map { snapshot.point(for: $0.coordinate) }
        let scale = SpeedScale(speeds: samples.map(\.speed))

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            snapshot.image.draw(at: .zero)

            let cg = context.cgContext
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            // A single casing under the whole track first, because a thin
            // coloured line over satellite imagery or busy coastline is close
            // to invisible — and drawing it per segment would leave the casing
            // painted over the neighbouring segment's colour.
            let casing = UIBezierPath()
            casing.move(to: points[0])
            for point in points.dropFirst() { casing.addLine(to: point) }
            casing.lineWidth = 4.5
            casing.lineJoinStyle = .round
            casing.lineCapStyle = .round
            UIColor.white.withAlphaComponent(0.9).setStroke()
            casing.stroke()

            // Then the track itself, coloured by speed. Segments are drawn
            // individually: the fast runs are what a rider scans the list for.
            cg.setLineWidth(2.6)
            for index in 1..<points.count {
                let speed = max(samples[index - 1].speed, samples[index].speed)
                cg.setStrokeColor(speedRampColour(speed, scale: scale).cgColor)
                cg.move(to: points[index - 1])
                cg.addLine(to: points[index])
                cg.strokePath()
            }
        }
    }

    /// A region that holds the whole track with a little air around it.
    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let centre = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // A floor on the span keeps a short session from being framed so tightly
        // that the map is one featureless tile.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.35, 0.004),
            longitudeDelta: max((maxLon - minLon) * 1.35, 0.004)
        )
        return MKCoordinateRegion(center: centre, span: span)
    }
}

/// The thumbnail itself: a placeholder until the snapshot arrives.
struct TrackThumbnail: View {

    let id: UUID
    let samples: [PreviewSample]
    var style: MapStyleOption = .standard
    var height: CGFloat = 132

    // The window's scale, not `UIScreen.main`'s — on an iPad the app lives in
    // a window that can sit on any display, including an external one.
    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            // The track's own shape, drawn immediately. It is
                            // the part the rider recognises, and showing it
                            // while the map loads beats a grey box.
                            TrackShape(coordinates: samples.map(\.coordinate))
                                .stroke(.tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .padding(10)
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: "\(proxy.size.width)-\(samples.count)-\(style.rawValue)") {
                guard proxy.size.width > 1 else { return }
                image = await TrackThumbnailCache.shared.image(
                    id: id,
                    samples: samples,
                    size: CGSize(width: proxy.size.width, height: proxy.size.height),
                    style: style,
                    scale: displayScale
                )
            }
        }
        .frame(height: height)
    }
}

/// The track normalised into whatever box it is given — no map, just the shape.
struct TrackShape: Shape {

    let coordinates: [CLLocationCoordinate2D]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard coordinates.count > 1 else { return path }

        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        // Longitude degrees shrink with latitude; ignoring that would squash a
        // session at 60° N into something the rider would not recognise.
        let latitudeSpan = max(maxLat - minLat, 1e-6)
        let longitudeSpan = max((maxLon - minLon) * cos(minLat * .pi / 180), 1e-6)
        let scale = min(rect.width / longitudeSpan, rect.height / latitudeSpan)
        let offsetX = rect.midX - longitudeSpan * scale / 2
        let offsetY = rect.midY - latitudeSpan * scale / 2

        for (index, coordinate) in coordinates.enumerated() {
            let x = offsetX + (coordinate.longitude - minLon) * cos(minLat * .pi / 180) * scale
            let y = offsetY + (maxLat - coordinate.latitude) * scale
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
