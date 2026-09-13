import MapKit
import OpenWaterSpots
import SwiftUI

/// The wind wash as one picture over the Spots map, with the pins left clear.
///
/// **Why.** The wash was 1,700 `MapPolygon`s, each one flat colour, and a
/// grid of translucent quads always shows its own grid: rectangles the eye
/// picks out, and a hairline wherever two meet. The television stopped
/// drawing it that way on 2026-09-03 — see `WashRaster`, which renders the
/// field to one small bitmap sampled bilinearly at every pixel, so the wash
/// is the smooth surface the model describes. The phone has been building
/// that picture every hour since, and throwing it away.
///
/// **Why the holes.** A SwiftUI `Map` has no way to put an image *under* its
/// own annotations, so the picture has to go over the whole map — and over
/// the pins. The television redrew its few badges above it; this map's pins
/// are many and tappable, and lifting them out of MapKit would put every one
/// of them into SwiftUI's per-frame layout. So the pins stay where they are,
/// and the picture is cut away wherever one stands: a pin reads exactly as it
/// did, and taps go straight through to it.
///
/// **Glued to the map.** Positioned through the proxy every frame, on the same
/// clock the comets already run, so it stays with the world through pan, zoom
/// and rotation. The picture is placed by three corners — an affine map from
/// its pixels to the glass — which is what keeps it right when the map is
/// turned. A tilted map would need a projection, not an affine; the Spots map
/// turns tilt off while this is showing.
struct WashImageLayer: View {

    let raster: WashRaster
    let proxy: MapProxy
    let holes: [WashHole]

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let region = raster.region
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        guard let nw = proxy.convert(CLLocationCoordinate2D(latitude: north, longitude: west), to: .local),
              let ne = proxy.convert(CLLocationCoordinate2D(latitude: north, longitude: east), to: .local),
              let sw = proxy.convert(CLLocationCoordinate2D(latitude: south, longitude: west), to: .local)
        else { return }

        // The picture's pixels onto the glass: x along the north edge, y down
        // the west edge. Stretching it is the GPU's job, and interpolating it
        // smoothly is the whole point — the bitmap is small by design.
        let width = CGFloat(raster.image.width), height = CGFloat(raster.image.height)
        var picture = context
        picture.concatenate(CGAffineTransform(a: (ne.x - nw.x) / width, b: (ne.y - nw.y) / width,
                                              c: (sw.x - nw.x) / height, d: (sw.y - nw.y) / height,
                                              tx: nw.x, ty: nw.y))
        picture.draw(Image(decorative: raster.image, scale: 1).interpolation(.high),
                     in: CGRect(x: 0, y: 0, width: width, height: height))

        // Then the pins, cut out of it. Pins do not turn with the map, so
        // neither do their holes.
        context.blendMode = .destinationOut
        for hole in holes {
            guard let point = proxy.convert(hole.coordinate, to: .local),
                  point.x > -80, point.x < size.width + 80,
                  point.y > -80, point.y < size.height + 80
            else { continue }
            context.fill(hole.path(at: point), with: .color(.black))
        }
    }
}

/// Where a pin stands and roughly what shape it is, so the wash can leave it
/// clear. Sized from the pin views themselves and padded a little: a hole a
/// point too big is a hairline of bare map around a pin, and a hole a point
/// too small is the edge of a pin wearing the weather.
struct WashHole {

    enum Anchor { case bottom, center }

    enum Shape {
        /// A rounded capsule. `tail` is the spot pin's pointer, drawn under it.
        case capsule(width: CGFloat, height: CGFloat, tail: Bool)
        case circle(diameter: CGFloat)
    }

    let coordinate: CLLocationCoordinate2D
    let anchor: Anchor
    let shape: Shape

    /// Slack around every pin, for its shadow and for a fast fling, where the
    /// map can be a frame ahead of this layer.
    private static let pad: CGFloat = 3

    func path(at point: CGPoint) -> Path {
        let pad = Self.pad
        var path = Path()
        switch shape {
        case let .circle(diameter):
            let centre = anchor == .bottom ? CGPoint(x: point.x, y: point.y - diameter / 2) : point
            let side = diameter + pad * 2
            path.addEllipse(in: CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                                       width: side, height: side))
        case let .capsule(width, height, tail):
            // A spot pin's tail is nine points under the capsule; anchored at
            // the bottom, that is where its point is.
            let tailHeight: CGFloat = tail ? 9 : 0
            let bottom = anchor == .bottom ? point.y - tailHeight : point.y + height / 2
            let rect = CGRect(x: point.x - width / 2 - pad, y: bottom - height - pad,
                              width: width + pad * 2, height: height + pad * 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
            if tail {
                let tip = CGPoint(x: point.x, y: point.y - 3)
                path.move(to: CGPoint(x: tip.x - 8, y: bottom - 2))
                path.addLine(to: CGPoint(x: tip.x + 8, y: bottom - 2))
                path.addLine(to: CGPoint(x: tip.x, y: tip.y + pad))
                path.closeSubpath()
            }
        }
        return path
    }
}
