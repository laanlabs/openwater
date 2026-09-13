import CoreImage
import CoreImage.CIFilterBuiltins
import MapKit
import OpenWaterCore
import SwiftUI
import UIKit

// MARK: - One picture in the loop

/// One picture in a radar loop: a set of slippy tiles from a radar service, or
/// a single georeferenced image from the HRRR. Both end up as one map-sized
/// bitmap; they differ only in how the bitmap is composed.
public enum RadarFrame: Hashable, Sendable {
    case tiles(RadarSource)
    case hrrr(HRRRReflectivity.Frame)

    /// The picture's identity, for the image cache and the motion table.
    public var stamp: String {
        switch self {
        case .tiles(let source):
            if case .rainViewer(let frame) = source { return frame.id }
            if case .noaa(let region, let product) = source {
                return "noaa-\(region.rawValue)-\(product.rawValue)"
            }
            return "noaa"
        case .hrrr(let frame):
            return frame.id
        }
    }
}

/// Where a latitude and longitude land on the glass, as two constants each,
/// captured on the main thread so a render off it can place a picture.
///
/// Longitude is linear on a Mercator map. Latitude is not — it is linear in
/// `ln(tan(π/4 + φ/2))` — and an equirectangular picture stretched straight
/// onto the map would put a shower off by a few kilometres at the edges of a
/// regional view.
private struct GeoPlacement: Sendable {
    let x0: Double, kx: Double, lon0: Double
    let y0: Double, ky: Double, merc0: Double

    static func merc(_ latitude: Double) -> Double {
        let clamped = min(max(latitude, -85), 85) * .pi / 180
        return log(tan(.pi / 4 + clamped / 2))
    }

    func x(of longitude: Double) -> CGFloat { CGFloat(x0 + (longitude - lon0) * kx) }
    func y(of latitude: Double) -> CGFloat { CGFloat(y0 + (Self.merc(latitude) - merc0) * ky) }
}

// MARK: - The map

/// A base map with the radar painted over it as a flat image.
///
/// Not a tile overlay. Every attempt that animated `MKTileOverlay`s —
/// swapping them, cross-fading them, mutating them — flickered, because
/// MapKit re-composites a tile overlay's whole geometry each time it changes
/// and does it on its own schedule. A radar loop cannot be smooth on top of
/// that: the television found it first, and the phone kept doing it for a
/// week longer, which is what "the loop disappears" was.
///
/// So each frame is rendered *once* into a single `UIImage` the size of the
/// map, geo-registered by asking the map where each tile's rectangle lands,
/// and the loop is a `UIImageView` swapping its `image` — a pointer
/// assignment the GPU draws in one frame. One alignment holds for every frame
/// of a set; a change of place or zoom rebuilds the set.
///
/// **Shared by both apps.** The television's map never moves. The phone's
/// moves under a finger, so with `isInteractive` the picture fades while the
/// map is moving — drawn for the rectangle being left, it would slide off the
/// coast it describes — and the set is redrawn for wherever the map comes to
/// rest, starting with the frame on the glass.
public struct RadarImageMap: UIViewRepresentable {

    public let region: MKCoordinateRegion
    public let frames: [RadarFrame]
    public let index: Int
    /// How long a change of frame has to play out, or nil to cut. See
    /// `Coordinator.show`.
    public let animation: TimeInterval?
    public let isActive: Bool
    @Binding public var loaded: Double
    /// Whether the map is the rider's to pan and zoom. With it on, `region`
    /// is only where the map opens.
    public let isInteractive: Bool
    public let configuration: MKMapConfiguration?
    public let showsUserLocation: Bool
    /// The bitmap's pixels per point. Half on the television, whose frames
    /// are 1080p and whose memory is short; whole on a phone, whose screen is
    /// a fifth the size in points and would otherwise draw radar in blocks.
    public let renderScale: CGFloat
    public let onRegionChange: ((MKCoordinateRegion) -> Void)?

    public init(region: MKCoordinateRegion, frames: [RadarFrame], index: Int,
                animation: TimeInterval?, isActive: Bool, loaded: Binding<Double>,
                isInteractive: Bool = false, configuration: MKMapConfiguration? = nil,
                showsUserLocation: Bool = false, renderScale: CGFloat = 0.5,
                onRegionChange: ((MKCoordinateRegion) -> Void)? = nil) {
        self.region = region
        self.frames = frames
        self.index = index
        self.animation = animation
        self.isActive = isActive
        self._loaded = loaded
        self.isInteractive = isInteractive
        self.configuration = configuration
        self.showsUserLocation = showsUserLocation
        self.renderScale = renderScale
        self.onRegionChange = onRegionChange
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = configuration ?? MKStandardMapConfiguration(elevationStyle: .flat)
        map.isUserInteractionEnabled = isInteractive
        map.showsUserLocation = showsUserLocation
        map.setRegion(region, animated: false)
        configure(context.coordinator)
        context.coordinator.attach(to: map)
        context.coordinator.update(frames: frames, index: index, animation: animation,
                                   region: region, active: isActive, to: map)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        // Only on a real change of style: reassigning restyles the whole map.
        if let configuration, type(of: map.preferredConfiguration) != type(of: configuration) {
            map.preferredConfiguration = configuration
        }
        configure(context.coordinator)
        context.coordinator.update(frames: frames, index: index, animation: animation,
                                   region: region, active: isActive, to: map)
    }

    private func configure(_ coordinator: Coordinator) {
        coordinator.loaded = $loaded
        coordinator.isInteractive = isInteractive
        coordinator.renderScale = renderScale
        coordinator.onRegionChange = onRegionChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject, MKMapViewDelegate {

        /// Both image views, faded as one while the map is moving.
        private let overlay = UIView()
        /// The radar, as one flat picture over the base map.
        private let radarView = UIImageView()
        /// The frame arriving, while a change of frame is being drawn as
        /// motion — see `show`. Empty and invisible the rest of the time.
        private let arrivingView = UIImageView()
        /// One rendered image per frame, keyed by the frame's own stamp.
        private var images: [String: UIImage] = [:]
        /// How far the echoes moved from one frame to the next, in points,
        /// keyed "from>to". Measured from the rendered pictures once both
        /// exist — see `estimateMotion`.
        private var motion: [String: CGVector] = [:]
        /// Which frame is on the glass, so a change can be told apart from
        /// a repeat and a step forward from a jump.
        private var shownStamp: String?
        private var shownIndex: Int?
        /// What the current image set was built for — frames plus the exact
        /// rectangle. A new signature means a rebuild.
        private var signature = ""
        /// The rectangle the picture on the glass was drawn for.
        private var drawnBox = ""
        private var buildTask: Task<Void, Never>?
        var loaded: Binding<Double>?
        var isInteractive = false
        var renderScale: CGFloat = 0.5
        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        /// A finger is moving the map: nothing is drawn until it stops.
        private var isMoving = false

        /// The last thing SwiftUI asked for, kept so the map's own callbacks
        /// can finish a render the view was too young for — see `update`.
        private var latest: (frames: [RadarFrame], index: Int, animation: TimeInterval?, region: MKCoordinateRegion)?

        /// How strongly the sweep sits over the chart.
        private static let strength: CGFloat = 0.78

        func attach(to map: MKMapView) {
            overlay.isUserInteractionEnabled = false
            overlay.frame = map.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            map.addSubview(overlay)
            for view in [radarView, arrivingView] {
                view.contentMode = .scaleToFill
                view.isUserInteractionEnabled = false
                view.frame = overlay.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.addSubview(view)
            }
            radarView.alpha = Self.strength
            arrivingView.alpha = 0
            map.delegate = self
        }

        deinit { buildTask?.cancel() }

        func update(frames: [RadarFrame], index: Int, animation: TimeInterval?,
                    region: MKCoordinateRegion, active: Bool, to map: MKMapView) {
            guard active else { return free() }
            // A map a finger moves is wherever the map *is*, not where the
            // screen first asked it to open.
            let region = isInteractive ? map.region : region
            latest = (frames, index, animation, region)
            // Drawn for where the map comes to rest, not for every frame of
            // the pan on the way there.
            guard !isMoving else { return }
            let sig = Self.signature(of: frames, region: region)
            if sig != signature {
                // A map with no size yet cannot be rendered into, and the
                // signature is only claimed once it has been. This was the
                // "Rain shows nothing after Rain forecast" bug on the
                // television: a render asked for before layout composed the
                // tiles into zero points, and — signature claimed — nothing
                // ever asked again. The first render now waits for the map's
                // own region callback below.
                if rebuild(frames: frames, region: region, map: map) {
                    signature = sig
                }
            }
            show(frames: frames, index: index, over: animation)
        }

        /// The map has a size, or a new one: if a render is owed, do it now.
        private func retryIfOwed(_ map: MKMapView) {
            guard signature.isEmpty, let latest, map.bounds.width > 0 else { return }
            update(frames: latest.frames, index: latest.index, animation: latest.animation,
                   region: latest.region, active: true, to: map)
        }

        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard isInteractive, !isMoving, mapView.bounds.width > 0, !signature.isEmpty else { return }
            isMoving = true
            // The set being built is for the rectangle being left; its frames
            // would land in the wrong place.
            buildTask?.cancel()
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState]) {
                self.overlay.alpha = 0
            }
        }

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChange?(mapView.region)
            if isMoving {
                isMoving = false
                // Owed a full set for the new rectangle, even where the
                // rectangle rounds to the old one: the build in flight was
                // cancelled when the move began.
                signature = ""
                if let latest {
                    update(frames: latest.frames, index: latest.index, animation: latest.animation,
                           region: mapView.region, active: true, to: mapView)
                }
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
                    self.overlay.alpha = 1
                }
            }
            retryIfOwed(mapView)
        }

        public func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            retryIfOwed(mapView)
        }

        /// Drop everything the screen was holding. The signature is cleared
        /// too, so coming back rebuilds from scratch rather than showing
        /// nothing.
        private func free() {
            guard !images.isEmpty || buildTask != nil else { return }
            buildTask?.cancel()
            buildTask = nil
            images = [:]
            motion = [:]
            settle()
            radarView.image = nil
            shownStamp = nil
            shownIndex = nil
            signature = ""
            drawnBox = ""
            loaded?.wrappedValue = 0
        }

        /// Put a frame on the glass.
        ///
        /// Three ways, by what the change is:
        ///
        /// - **The next frame, while playing, with its motion known:** the
        ///   frame on screen slides along the vector the echoes were measured
        ///   to have moved while fading out, and the new frame slides in from
        ///   behind that same vector while fading up, over the whole interval
        ///   until the frame after. The eye reads this as the cells
        ///   travelling — which is the point of a loop: not a dozen pictures
        ///   but where the rain is going.
        /// - **Any other change while playing, or a step by hand:** a short
        ///   cross-dissolve. A jump from the last frame back to the first is
        ///   not motion and must not be drawn as some.
        /// - **The same frame again:** nothing.
        private func show(frames: [RadarFrame], index: Int, over duration: TimeInterval?) {
            guard frames.indices.contains(index) else { return }
            let stamp = frames[index].stamp
            guard let image = images[stamp], stamp != shownStamp else { return }

            let from = shownStamp
            let steppedForward = shownIndex.map { $0 + 1 == index } ?? false
            settle()

            if let duration, steppedForward, let from,
               let vector = motion["\(from)>\(stamp)"], hypot(vector.dx, vector.dy) > 0.5 {
                arrivingView.image = image
                arrivingView.transform = CGAffineTransform(translationX: -vector.dx, y: -vector.dy)
                arrivingView.alpha = 0
                UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
                    self.radarView.transform = CGAffineTransform(translationX: vector.dx, y: vector.dy)
                    self.radarView.alpha = 0
                    self.arrivingView.transform = .identity
                    self.arrivingView.alpha = Self.strength
                } completion: { finished in
                    // Hand the arrived picture to the resting view whether or
                    // not the animation ran its course: a new frame may have
                    // cut in, and it will have settled us already.
                    guard finished, self.arrivingView.image === image else { return }
                    self.settle()
                    self.radarView.image = image
                }
            } else {
                UIView.transition(with: radarView, duration: 0.22,
                                  options: [.transitionCrossDissolve, .beginFromCurrentState]) {
                    self.radarView.image = image
                }
            }
            shownStamp = stamp
            shownIndex = index
        }

        /// Both views at rest: whatever is arriving is now simply shown, and
        /// nothing is mid-flight. Safe to call at any moment.
        private func settle() {
            radarView.layer.removeAllAnimations()
            arrivingView.layer.removeAllAnimations()
            if let arrived = arrivingView.image, arrivingView.alpha > 0 {
                radarView.image = arrived
            }
            radarView.transform = .identity
            radarView.alpha = Self.strength
            arrivingView.transform = .identity
            arrivingView.alpha = 0
            arrivingView.image = nil
        }

        /// Start rendering the set. False when the map has no size yet and
        /// nothing could be drawn — the caller leaves the signature unclaimed
        /// so a later pass tries again.
        @discardableResult
        private func rebuild(frames: [RadarFrame], region: MKCoordinateRegion, map: MKMapView) -> Bool {
            buildTask?.cancel()
            images = [:]
            motion = [:]
            loaded?.wrappedValue = 0

            if !isInteractive { map.setRegion(region, animated: false) }
            map.layoutIfNeeded()
            let size = map.bounds.size
            guard size.width > 0 else { return false }

            // Whatever is on the glass is re-drawn from this set, so it no
            // longer counts as shown — a fresh copy of the same frame would
            // otherwise be refused as a repeat. The picture itself stays up
            // until its replacement lands, unless it was drawn for another
            // rectangle, where it would now sit on the wrong coast.
            settle()
            shownStamp = nil
            shownIndex = nil
            let box = Self.box(of: map.region)
            if box != drawnBox { radarView.image = nil }
            drawnBox = box

            guard !frames.isEmpty else { loaded?.wrappedValue = 1; return true }

            // The region the map *actually* shows, not the one it was asked
            // for. MapKit fits the requested region into the view's shape,
            // which makes the shown area wider — and tiles computed from the
            // narrower request left one side of the map bare, with a hard
            // edge where the tiles stopped.
            let visible = map.region
            let zoom = Self.renderZoom(for: visible)
            let tiles = RadarTiles.tiles(covering: visible, zoom: zoom)
            // Where each tile's square lands on the glass — computed once,
            // on the main thread, because it is the same for every frame.
            let placements: [(x: Int, y: Int, rect: CGRect)] = tiles.map { tile in
                // On a Mercator map a tile's square projects to an
                // axis-aligned rectangle, so two corners define it exactly.
                let nw = Self.corner(x: tile.x, y: tile.y, z: zoom)
                let se = Self.corner(x: tile.x + 1, y: tile.y + 1, z: zoom)
                let p1 = map.convert(nw, toPointTo: map)
                let p2 = map.convert(se, toPointTo: map)
                let rect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                  width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
                return (tile.x, tile.y, rect)
            }
            guard !placements.isEmpty else { loaded?.wrappedValue = 1; return true }

            // The same question for a whole picture: two points each way,
            // asked of the map here, so the render can place any latitude
            // and longitude without coming back to the main thread.
            let centre = visible.center
            let west = CLLocationCoordinate2D(latitude: centre.latitude,
                                              longitude: centre.longitude - visible.span.longitudeDelta / 2)
            let east = CLLocationCoordinate2D(latitude: centre.latitude,
                                              longitude: centre.longitude + visible.span.longitudeDelta / 2)
            let north = CLLocationCoordinate2D(latitude: centre.latitude + visible.span.latitudeDelta / 2,
                                               longitude: centre.longitude)
            let south = CLLocationCoordinate2D(latitude: centre.latitude - visible.span.latitudeDelta / 2,
                                               longitude: centre.longitude)
            let pw = map.convert(west, toPointTo: map), pe = map.convert(east, toPointTo: map)
            let pn = map.convert(north, toPointTo: map), ps = map.convert(south, toPointTo: map)
            let geo = GeoPlacement(
                x0: pw.x, kx: (pe.x - pw.x) / (east.longitude - west.longitude), lon0: west.longitude,
                y0: pn.y, ky: (ps.y - pn.y) / (GeoPlacement.merc(south.latitude) - GeoPlacement.merc(north.latitude)),
                merc0: GeoPlacement.merc(north.latitude))
            let scale = renderScale

            // The frame on the glass first, then the rest in order. The loop
            // opens on its newest observation, which is the *last* frame — so
            // drawn oldest-first, the one picture a rider is looking at
            // arrived after every other, and on a phone that redraws after
            // every pan that was seconds of bare map each time.
            let first = min(max(latest?.index ?? 0, 0), frames.count - 1)
            let order = [first] + frames.indices.filter { $0 != first }

            buildTask = Task { @MainActor [weak self] in
                var rendered: [Int: UIImage] = [:]
                for (done, i) in order.enumerated() {
                    if Task.isCancelled { return }
                    let frame = frames[i]
                    let image: UIImage?
                    switch frame {
                    case .tiles(let source):
                        image = await Self.render(source: source, placements: placements,
                                                  zoom: zoom, size: size, scale: scale)
                    case .hrrr(let hrrr):
                        image = await Self.render(picture: hrrr, visible: visible, geo: geo,
                                                  size: size, scale: scale)
                    }
                    if Task.isCancelled { return }
                    if let image {
                        rendered[i] = image
                        self?.images[frame.stamp] = image
                        // How far the weather moved to and from each
                        // neighbour already drawn, for `show` to draw as
                        // travel.
                        for (a, b) in [(i - 1, i), (i, i + 1)] {
                            guard let before = rendered[a], let after = rendered[b] else { continue }
                            let vector = await Self.estimateMotion(from: before, to: after)
                            if Task.isCancelled { return }
                            self?.motion["\(frames[a].stamp)>\(frames[b].stamp)"] = vector
                        }
                    }
                    // Setting loaded re-runs the SwiftUI body, which calls
                    // `update` → `show`, so a frame appears as soon as it is
                    // ready rather than only when the set is whole.
                    self?.loaded?.wrappedValue = Double(done + 1) / Double(frames.count)
                }
            }
            return true
        }

        /// How far the echoes shifted from one picture to the next, as one
        /// vector in points.
        ///
        /// Block matching on the alpha channel: both pictures are shrunk to
        /// about a hundred pixels across — where the rain is, not what colour
        /// — and the offset that lines the second up best over the first is
        /// searched for within a dozen small pixels each way, which at a
        /// regional zoom is a couple of hundred kilometres an hour, more than
        /// weather moves. One vector for the whole picture: a storm system's
        /// cells share a steering flow, and a single translation is what the
        /// eye needs to read the loop as motion. If nothing matches better
        /// than not moving, nothing moves.
        nonisolated private static func estimateMotion(from before: UIImage, to after: UIImage) async -> CGVector {
            let width = 120
            let height = max(2, Int((Double(width) * Double(before.size.height) / Double(before.size.width)).rounded()))
            guard let a = coverage(of: before, width: width, height: height),
                  let b = coverage(of: after, width: width, height: height)
            else { return .zero }
            let reach = 12
            func cost(dx: Int, dy: Int) -> Int {
                // Sum of absolute differences where the shifted second
                // picture overlaps the first.
                var total = 0
                for y in max(0, -dy)..<min(height, height - dy) {
                    let rowA = y * width, rowB = (y + dy) * width
                    for x in max(0, -dx)..<min(width, width - dx) {
                        total += abs(Int(a[rowA + x]) - Int(b[rowB + x + dx]))
                    }
                }
                return total
            }
            let still = cost(dx: 0, dy: 0)
            guard still > 0 else { return .zero }
            var best = (dx: 0, dy: 0, cost: still)
            for dy in -reach...reach {
                for dx in -reach...reach where dx != 0 || dy != 0 {
                    let c = cost(dx: dx, dy: dy)
                    if c < best.cost { best = (dx, dy, c) }
                }
            }
            // Only a clear improvement counts. Noise between two frames can
            // always be shaved a little by a one-pixel nudge, and drawing that
            // as travel would make a stationary cell jitter.
            guard Double(best.cost) < Double(still) * 0.92 else { return .zero }
            // Between the pixels: a parabola through the costs either side of
            // the best offset says where the true minimum sits.
            func peak(_ lower: Int, _ centre: Int, _ upper: Int) -> Double {
                let curve = Double(lower - 2 * centre + upper)
                return curve > 0 ? max(-0.5, min(0.5, 0.5 * Double(lower - upper) / curve)) : 0
            }
            let subX = abs(best.dx) < reach
                ? peak(cost(dx: best.dx - 1, dy: best.dy), best.cost, cost(dx: best.dx + 1, dy: best.dy)) : 0
            let subY = abs(best.dy) < reach
                ? peak(cost(dx: best.dx, dy: best.dy - 1), best.cost, cost(dx: best.dx, dy: best.dy + 1)) : 0
            let pointsPerPixel = Double(before.size.width) / Double(width)
            return CGVector(dx: (Double(best.dx) + subX) * pointsPerPixel,
                            dy: (Double(best.dy) + subY) * pointsPerPixel)
        }

        /// A picture's alpha, small: where there is weather at all.
        nonisolated private static func coverage(of image: UIImage, width: Int, height: Int) -> [UInt8]? {
            guard let cg = image.cgImage else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = CGInterpolationQuality.medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The alpha byte of each pixel is the only thing wanted.
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }

        /// One HRRR picture, cut to the view and laid onto the map.
        ///
        /// 1. **Crop.** The picture is the whole continent at 0.02° a pixel;
        ///    only the part under the view, plus a margin, is touched.
        /// 2. **Key.** The server paints on black and draws the faintest
        ///    returns in pale greys. Both go transparent: the black because it
        ///    is ground, the greys because they were a speckle of white
        ///    squares around every cell. Colour with any saturation is rain.
        /// 3. **Reproject.** The source is equirectangular and the map is
        ///    Mercator, so the crop is resampled row by row into one image
        ///    whose rows *are* Mercator.
        /// 4. **Draw and soften.** Drawn once, scaled with bicubic
        ///    interpolation, then blurred by about a third of one source
        ///    pixel's width on screen — the model has no detail below its
        ///    pixel, and pretending the squares are edges is the only lie a
        ///    blur tells less of.
        nonisolated private static func render(picture frame: HRRRReflectivity.Frame,
                                               visible: MKCoordinateRegion,
                                               geo: GeoPlacement,
                                               size: CGSize, scale: CGFloat) async -> UIImage? {
            guard let whole = await HRRRReflectivity.image(for: frame) else { return nil }
            let bounds = frame.bounds(width: whole.width, height: whole.height)
            let dpp = frame.degreesPerPixel

            // 1. Crop.
            let margin = 0.5
            let wantWest = max(bounds.west, visible.center.longitude - visible.span.longitudeDelta / 2 - margin)
            let wantEast = min(bounds.east, visible.center.longitude + visible.span.longitudeDelta / 2 + margin)
            let wantNorth = min(bounds.north, visible.center.latitude + visible.span.latitudeDelta / 2 + margin)
            let wantSouth = max(bounds.south, visible.center.latitude - visible.span.latitudeDelta / 2 - margin)
            guard wantEast > wantWest, wantNorth > wantSouth else { return nil }
            let x0 = Int((wantWest - bounds.west) / dpp)
            let x1 = min(whole.width, Int(((wantEast - bounds.west) / dpp).rounded(.up)))
            let y0 = Int((bounds.north - wantNorth) / dpp)
            let y1 = min(whole.height, Int(((bounds.north - wantSouth) / dpp).rounded(.up)))
            guard x1 > x0, y1 > y0,
                  let crop = whole.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            else { return nil }
            let width = crop.width, height = crop.height
            let latTop = bounds.north - Double(y0) * dpp
            let latBottom = bounds.north - Double(y1) * dpp
            let lonLeft = bounds.west + Double(x0) * dpp
            let lonRight = bounds.west + Double(x1) * dpp

            // 2. Key. Read the crop as RGBA and decide, pixel by pixel.
            var source = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            guard let reader = CGContext(data: &source, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            reader.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            for i in stride(from: 0, to: source.count, by: 4) {
                let r = Int(source[i]), g = Int(source[i + 1]), b = Int(source[i + 2])
                let brightest = max(r, g, b), darkest = min(r, g, b)
                let isGround = brightest < 12
                let isGrey = brightest - darkest < 30
                if isGround || isGrey {
                    source[i] = 0; source[i + 1] = 0; source[i + 2] = 0; source[i + 3] = 0
                }
            }

            // 3. Reproject: one output row per source row, placed by latitude.
            let mercTop = GeoPlacement.merc(latTop), mercBottom = GeoPlacement.merc(latBottom)
            var projected = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                let t = (Double(row) + 0.5) / Double(height)
                let merc = mercTop + (mercBottom - mercTop) * t
                let latitude = atan(sinh(merc)) * 180 / .pi
                let sourceRow = (latTop - latitude) / dpp - 0.5
                let above = max(0, min(height - 1, Int(floor(sourceRow))))
                let below = max(0, min(height - 1, above + 1))
                let blend = max(0, min(1, sourceRow - Double(above)))
                for column in 0..<width {
                    let a = (above * width + column) * 4, b = (below * width + column) * 4, o = (row * width + column) * 4
                    for channel in 0..<4 {
                        let value = Double(source[a + channel]) * (1 - blend) + Double(source[b + channel]) * blend
                        projected[o + channel] = UInt8(max(0, min(255, value.rounded())))
                    }
                }
            }
            guard let writer = CGContext(data: &projected, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let mercator = writer.makeImage()
            else { return nil }

            // 4. Draw, then soften.
            let left = geo.x(of: lonLeft), right = geo.x(of: lonRight)
            let top = geo.y(of: latTop), bottom = geo.y(of: latBottom)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = false
            let sharp = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: mercator).draw(in: CGRect(x: left, y: top,
                                                           width: right - left, height: bottom - top))
            }
            // A third of a source pixel's width on the glass is enough to lose
            // the square without losing the cell — on a television, where a
            // regional view makes each pixel twenty-odd points. At a phone's
            // zoom a pixel is two or three points and a third of it is no
            // blur at all, while the model's own cells, several pixels
            // across, still read as blocks. So never less than three points.
            let pixelPoints = Double(right - left) / Double(width)
            let radius = max(0.8, min(9, max(pixelPoints * 0.34, 3) * Double(scale)))
            return soften(sharp, radius: radius) ?? sharp
        }

        /// One shared Core Image context: making one per frame is the
        /// expensive part of using Core Image at all.
        nonisolated private static let softener = CIContext(options: [.useSoftwareRenderer: false])

        /// A Gaussian blur, cropped back to the picture's own extent — the
        /// filter grows the image by its radius on every side, and left as
        /// is that growth would shift the whole overlay down and right.
        nonisolated private static func soften(_ image: UIImage, radius: Double) -> UIImage? {
            guard let cg = image.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(radius)
            guard let output = filter.outputImage?.cropped(to: input.extent),
                  let result = softener.createCGImage(output, from: input.extent)
            else { return nil }
            return UIImage(cgImage: result, scale: image.scale, orientation: .up)
        }

        /// Compose one frame's tiles into a single map-sized image, off the
        /// main thread — a dozen full-screen composites on the main actor was
        /// a visible hitch on entry.
        nonisolated private static func render(source: RadarSource,
                                               placements: [(x: Int, y: Int, rect: CGRect)],
                                               zoom: Int, size: CGSize, scale: CGFloat) async -> UIImage {
            let overlay = RadarTileOverlay(source: source)
            var pieces: [(CGRect, UIImage)] = []
            await withTaskGroup(of: (CGRect, UIImage?).self) { group in
                for place in placements {
                    group.addTask {
                        (place.rect, await tileImage(overlay, place.x, place.y, zoom))
                    }
                }
                for await (rect, image) in group where image != nil {
                    pieces.append((rect, image!))
                }
            }
            let format = UIGraphicsImageRendererFormat.default()
            // Radar is coarse and the image is stretched over the whole map
            // anyway; see `renderScale` for why the two apps differ.
            format.scale = scale
            format.opaque = false
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                for (rect, image) in pieces { image.draw(in: rect) }
            }
        }

        private static func tileImage(_ overlay: RadarTileOverlay,
                                      _ x: Int, _ y: Int, _ z: Int) async -> UIImage? {
            let data: Data? = await withCheckedContinuation { continuation in
                overlay.loadTile(at: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            return data.flatMap { UIImage(data: $0) }
        }

        private static func box(of region: MKCoordinateRegion) -> String {
            String(format: "%.3f,%.3f,%.3f", region.center.latitude,
                   region.center.longitude, region.span.latitudeDelta)
        }

        private static func signature(of frames: [RadarFrame], region: MKCoordinateRegion) -> String {
            frames.map(\.stamp).joined(separator: ",") + "|" + box(of: region)
        }

        /// The tile zoom to render at — roughly what fills the view, capped so
        /// the grid is a handful of tiles rather than a thousand.
        private static func renderZoom(for region: MKCoordinateRegion) -> Int {
            let span = max(region.span.longitudeDelta, 0.0001)
            return min(max(Int((log2(360 / span)).rounded()), 3), 9)
        }

        /// The north-west corner of a slippy tile, in latitude and longitude
        /// — the standard tile scheme, `y` counting down from the top.
        private static func corner(x: Int, y: Int, z: Int) -> CLLocationCoordinate2D {
            let n = pow(2.0, Double(z))
            let lon = Double(x) / n * 360 - 180
            let lat = atan(sinh(Double.pi * (1 - 2 * Double(y) / n))) * 180 / .pi
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
